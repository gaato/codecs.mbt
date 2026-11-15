// Snappy's framing format (framing_format.txt): a stream identifier chunk,
// then chunks of a type byte and a 3-byte length: compressed data and
// uncompressed data, each of at most 64 KiB with the masked CRC-32C of the
// uncompressed bytes, padding and other skippable chunks, and further
// stream identifiers. Nothing marks a stream's end.

///|
/// The stream identifier chunk's body.
let identifier : Bytes = b"sNaPpY"

///|
/// The largest compressed chunk body, as the snap crate takes it: the
/// checksum and the most a raw stream of 64 KiB takes (`raw_compress_bound`).
const MAX_COMPRESSED_BODY : Int32 = 4 + 32 + BLOCK_SIZE + BLOCK_SIZE / 6

///|
/// The CRC-32C of `data`, masked as the framing format stores it: rotated
/// right by 15 bits and added to 0xa282ead8.
fn masked_crc(data : BytesView) -> UInt32 {
  let crc = @crc32c.update_bytes(0, data)
  ((crc >> 15) | (crc << 17)) + 0xA282EAD8
}

///|
priv enum State {
  Header
  Body
  Skip
  Done
}

///|
/// A streaming decoder of Snappy's framing format. It holds a chunk's body
/// (at most 76,494 bytes) and its decoded bytes (at most 64 KiB), never the
/// whole input or output.
pub struct Decoder {
  priv until : @codec_bytes.Until
  priv verify_checksums : Bool
  priv hdr : FixedArray[Byte]
  priv mut hdr_len : Int32
  priv mut state : State
  priv mut kind : Int32
  priv mut length : Int32
  priv mut body : FixedArray[Byte]
  priv mut body_len : Int32
  priv mut out : FixedArray[Byte]
  priv mut out_len : Int32
  priv mut out_pos : Int32
  // Whether the stream identifier came, and data after it.
  priv mut identified : Bool
  priv mut data_seen : Bool
  priv mut failure : @codec.CodecError?
  // The error of the chunk waiting in `out`, raised once its bytes are out:
  // a CRC-32C that fails (they are provisional, as the contract has it), or
  // a raw stream that breaks off after them.
  priv mut pending : @codec.CodecError?
  priv mut consumed : Int32
  priv mut produced : Int32
}

///|
/// A decoder at the start of a stream. `until` says where it ends:
/// `EndOfInput`, the default, reads streams one after another up to the end
/// of the input, as the format allows; `EndOfMember` stops before a stream
/// identifier that follows data, the start of another stream, and consumes
/// nothing of it. `verify_checksums=false` skips the CRC-32C of each chunk.
pub fn Decoder::Decoder(
  until~ : @codec_bytes.Until = EndOfInput,
  verify_checksums~ : Bool = true,
) -> Decoder {
  {
    until,
    verify_checksums,
    hdr: FixedArray::make(4, b'\x00'),
    hdr_len: 0,
    state: Header,
    kind: 0,
    length: 0,
    body: FixedArray::make(0, b'\x00'),
    body_len: 0,
    out: FixedArray::make(0, b'\x00'),
    out_len: 0,
    out_pos: 0,
    identified: false,
    data_seen: false,
    failure: None,
    pending: None,
    consumed: 0,
    produced: 0,
  }
}

///|
/// Back to the state of a new decoder with the same options; the buffers'
/// memory is kept.
pub fn Decoder::reset(self : Decoder) -> Unit {
  self.hdr_len = 0
  self.state = Header
  self.body_len = 0
  self.out_len = 0
  self.out_pos = 0
  self.identified = false
  self.data_seen = false
  self.failure = None
  self.pending = None
  self.consumed = 0
  self.produced = 0
}

///|
/// Bytes the decoder holds: a chunk's body and its decoded bytes, allocated
/// at the first chunk that needs them, at most 76,494 and 65,536.
pub fn Decoder::memory_usage(self : Decoder) -> Int32 {
  self.hdr.length() + self.body.length() + self.out.length()
}

///|
/// Input bytes the latest `step` consumed: all of it on `NeedMoreInput`;
/// up to the error for a step that raised; for `TrailingData`, exactly up
/// to the end of the stream.
pub fn Decoder::last_consumed(self : Decoder) -> Int32 {
  self.consumed
}

///|
/// Output bytes the latest `step` wrote, a step that raised included.
pub fn Decoder::last_produced(self : Decoder) -> Int32 {
  self.produced
}

///|
/// Whether the stream has ended and all its output has been handed out.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  self.state is Done && self.out_pos == self.out_len
}

///|
/// Decodes from `input` into `output`. A chunk's bytes come out once it is
/// decoded, and `ChecksumMismatch` after them when its CRC-32C fails: they
/// are provisional, as the contract has it (`decompress` returns only
/// checked output).
/// `end` says whether `input` holds the last bytes: the stream ends there
/// (nothing marks the end; no bytes at all are the empty stream), and a
/// chunk cut short raises `Truncated`.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end~ : Bool,
) -> @codec_bytes.Status raise @codec.CodecError {
  self.consumed = 0
  self.produced = 0
  if self.failure is Some(err) {
    raise err
  }
  self.run(input, output, end) catch {
    err => return self.fail(err)
  }
}

///|
/// Records `err`, which every step raises again until `reset`.
fn Decoder::fail(
  self : Decoder,
  err : @codec.CodecError,
) -> @codec_bytes.Status raise @codec.CodecError {
  self.failure = Some(err)
  raise err
}

///|
fn Decoder::run(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end : Bool,
) -> @codec_bytes.Status raise @codec.CodecError {
  for ;; {
    // What waits goes out first; nothing more is decoded until it has.
    let n = (self.out_len - self.out_pos).min(output.length() - self.produced)
    if n > 0 {
      @blit.into_view(output, self.produced, self.out, self.out_pos, n)
      self.out_pos += n
      self.produced += n
    }
    if self.out_pos < self.out_len {
      return NeedMoreOutput
    }
    if self.pending is Some(err) {
      raise err
    }
    match self.state {
      Done => {
        if self.until is EndOfInput && self.consumed < input.length() {
          raise @codec.CodecError(TrailingData, "data after the last chunk")
        }
        return Done
      }
      Header => {
        if self.consumed == input.length() {
          guard end else { return NeedMoreInput }
          guard self.hdr_len == 0 else {
            raise @codec.CodecError(
              Truncated,
              "the input ends inside a chunk's header",
            )
          }
          // No chunk at all is the empty stream, as snap writes it.
          self.state = Done
          continue
        }
        // Another stream's identifier ends this one, under EndOfMember,
        // before any of its bytes is taken.
        if self.hdr_len == 0 &&
          self.until is EndOfMember &&
          self.data_seen &&
          input[self.consumed] == b'\xff' {
          self.state = Done
          continue
        }
        let take = (4 - self.hdr_len).min(input.length() - self.consumed)
        for i in 0..<take {
          self.hdr[self.hdr_len + i] = input[self.consumed + i]
        }
        self.hdr_len += take
        self.consumed += take
        if self.hdr_len < 4 {
          continue
        }
        self.hdr_len = 0
        self.begin_chunk()
      }
      Body => {
        let take = (self.length - self.body_len).min(
          input.length() - self.consumed,
        )
        self.body.blit_from_bytesview(
          self.body_len,
          input[self.consumed:self.consumed + take],
        )
        self.body_len += take
        self.consumed += take
        if self.body_len < self.length {
          guard !end else {
            raise @codec.CodecError(Truncated, "the input ends inside a chunk")
          }
          return NeedMoreInput
        }
        self.end_chunk()
        self.state = Header
      }
      Skip => {
        let take = self.length.min(input.length() - self.consumed)
        self.length -= take
        self.consumed += take
        if self.length > 0 {
          guard !end else {
            raise @codec.CodecError(Truncated, "the input ends inside a chunk")
          }
          return NeedMoreInput
        }
        self.state = Header
      }
    }
  }
}

///|
/// Takes the chunk the header holds: its type and length, checked.
fn Decoder::begin_chunk(self : Decoder) -> Unit raise @codec.CodecError {
  let kind = self.hdr[0].to_int()
  let length = self.hdr[1].to_int() |
    (self.hdr[2].to_int() << 8) |
    (self.hdr[3].to_int() << 16)
  guard self.identified || kind == 0xFF else {
    raise corrupt("not a Snappy framed stream: no stream identifier first")
  }
  self.kind = kind
  self.length = length
  self.body_len = 0
  let most = match kind {
    0xFF => {
      guard length == 6 else {
        raise corrupt("a stream identifier of \{length} bytes")
      }
      6
    }
    0x00 => {
      // The format allows longer compressed chunks, as long as they decode
      // to 64 KiB at most; no encoder writes one, since 64 KiB compresses
      // to no more than this, and the snap crate and golang/snappy hold no
      // more either.
      guard length <= MAX_COMPRESSED_BODY else {
        raise @codec.CodecError(
          LimitExceeded({
            resource: Memory,
            needed: Some(length.to_uint64()),
            limit: MAX_COMPRESSED_BODY.to_uint64(),
          }),
          "a compressed chunk of \{length} bytes, over the \{MAX_COMPRESSED_BODY} held",
        )
      }
      MAX_COMPRESSED_BODY
    }
    0x01 => 4 + BLOCK_SIZE
    _ if kind <= 0x7F =>
      raise corrupt("a reserved chunk that cannot be skipped (\{kind})")
    _ => {
      self.state = Skip
      return
    }
  }
  guard length <= most else {
    raise corrupt("a chunk of \{length} bytes, over \{most}")
  }
  guard kind == 0xFF || length >= 4 else {
    raise corrupt("a data chunk without its checksum")
  }
  if self.body.length() < most {
    self.body = FixedArray::make(most, b'\x00')
  }
  self.state = Body
}

///|
/// Decodes the chunk whose body is gathered, and checks it.
fn Decoder::end_chunk(self : Decoder) -> Unit raise @codec.CodecError {
  let body = self.body.unsafe_reinterpret_as_bytes()[0:self.length]
  if self.kind == 0xFF {
    guard body == identifier[:] else {
      raise corrupt("a stream identifier that is not sNaPpY")
    }
    self.identified = true
    return
  }
  if self.out.length() < BLOCK_SIZE {
    self.out = FixedArray::make(BLOCK_SIZE, b'\x00')
  }
  let stored = body[0].to_uint() |
    (body[1].to_uint() << 8) |
    (body[2].to_uint() << 16) |
    (body[3].to_uint() << 24)
  let data = body[4:]
  let n = if self.kind == 0x00 {
    let (length, used) = read_length(data)
    guard length <= BLOCK_SIZE.to_int64() else {
      raise corrupt("a chunk that decodes to more than 64 KiB")
    }
    let written = Ref(0)
    decode_elements(data[used:], self.out, 0, length.to_int(), written) catch {
      err => {
        self.out_len = written.val
        self.out_pos = 0
        self.pending = Some(err)
        return
      }
    }
    length.to_int()
  } else {
    self.out.blit_from_bytesview(0, data)
    data.length()
  }
  if self.verify_checksums {
    let decoded = self.out.unsafe_reinterpret_as_bytes()[0:n]
    if masked_crc(decoded) != stored {
      self.pending = Some(
        @codec.CodecError(
          ChecksumMismatch,
          "a chunk's CRC-32C does not match its data",
        ),
      )
    }
  }
  self.out_len = n
  self.out_pos = 0
  self.data_seen = true
}

///|
/// A streaming encoder of Snappy's framing format: the stream identifier,
/// then a chunk for each 64 KiB of input (the identifier alone for none,
/// where the snap crate writes nothing), compressed unless that saves less
/// than an eighth, as snappy's framing writers do. It holds 64 KiB of input
/// and a chunk's output.
pub struct Encoder {
  priv input : FixedArray[Byte]
  priv mut input_len : Int32
  priv out : Writer
  priv mut out_pos : Int32
  priv scratch : Writer
  priv table : FixedArray[UInt16]
  priv mut started : Bool
  priv mut finished : Bool
  priv mut done : Bool
  priv mut consumed : Int32
  priv mut produced : Int32
}

///|
/// An encoder at the start of a stream.
pub fn Encoder::Encoder() -> Encoder {
  {
    input: FixedArray::make(BLOCK_SIZE, b'\x00'),
    input_len: 0,
    out: Writer::new(10 + 8 + BLOCK_SIZE + 32 + BLOCK_SIZE / 6),
    out_pos: 0,
    scratch: Writer::new(32 + BLOCK_SIZE + BLOCK_SIZE / 6),
    table: FixedArray::make(1 << MAX_HASH_BITS, (0 : UInt16)),
    started: false,
    finished: false,
    done: false,
    consumed: 0,
    produced: 0,
  }
}

///|
/// Back to the state of a new encoder; the buffers' memory is kept.
pub fn Encoder::reset(self : Encoder) -> Unit {
  self.input_len = 0
  self.out.pos = 0
  self.out_pos = 0
  self.started = false
  self.finished = false
  self.done = false
  self.consumed = 0
  self.produced = 0
}

///|
/// Bytes the encoder holds, the same from the first step to the last: 64
/// KiB of input, a chunk's output and the raw stream it is made from, and
/// the hash table.
pub fn Encoder::memory_usage(self : Encoder) -> Int32 {
  self.input.length() +
  self.out.data.length() +
  self.scratch.data.length() +
  2 * self.table.length()
}

///|
/// Input bytes the latest `step` took.
pub fn Encoder::last_consumed(self : Encoder) -> Int32 {
  self.consumed
}

///|
/// Output bytes the latest `step` wrote.
pub fn Encoder::last_produced(self : Encoder) -> Int32 {
  self.produced
}

///|
/// Whether the stream has ended and all its output has been handed out.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.done
}

///|
/// Compresses from `input` into `output`: `Continue` takes input, `Flush`
/// writes what is held as a chunk, so that the output so far decodes to the
/// input so far, and `Finish` does so and ends the stream. Input that was
/// not taken (when the output is full) must be passed again, with the same
/// action. Answers `NeedMoreInput` once everything is taken and handed out,
/// `NeedMoreOutput` while output waits, `Done` once the stream has ended.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  action~ : @codec_bytes.EncodeAction,
) -> @codec_bytes.Status {
  self.consumed = 0
  self.produced = 0
  if self.done {
    return Done
  }
  let mut flushed = false
  for ;; {
    let n = (self.out.pos - self.out_pos).min(output.length() - self.produced)
    if n > 0 {
      @blit.into_view(output, self.produced, self.out.data, self.out_pos, n)
    }
    self.out_pos += n
    self.produced += n
    if self.out_pos < self.out.pos {
      return NeedMoreOutput
    }
    self.out.pos = 0
    self.out_pos = 0
    if self.finished {
      self.done = true
      return Done
    }
    if self.input_len == BLOCK_SIZE {
      self.write_chunk()
      continue
    }
    let take = (input.length() - self.consumed).min(BLOCK_SIZE - self.input_len)
    if take > 0 {
      self.input.blit_from_bytesview(
        self.input_len,
        input[self.consumed:self.consumed + take],
      )
      self.input_len += take
      self.consumed += take
      continue
    }
    match action {
      Continue => return NeedMoreInput
      Flush if !flushed && self.input_len > 0 => {
        flushed = true
        self.write_chunk()
      }
      Flush => return NeedMoreInput
      Finish => {
        if self.input_len > 0 {
          self.write_chunk()
        } else if !self.started {
          // A stream without data is the identifier alone, as the format
          // has every stream begin with it.
          self.write_identifier()
        }
        self.finished = true
      }
    }
  }
}

///|
/// Writes the stream identifier, which begins every stream.
fn Encoder::write_identifier(self : Encoder) -> Unit {
  self.started = true
  self.out.byte(0xFF)
  self.out.byte(6)
  self.out.byte(0)
  self.out.byte(0)
  self.out.data.blit_from_bytes(self.out.pos, identifier, 0, 6)
  self.out.pos += 6
}

///|
/// Writes the input held as one chunk.
fn Encoder::write_chunk(self : Encoder) -> Unit {
  if !self.started {
    self.write_identifier()
  }
  let n = self.input_len
  let data = self.input.unsafe_reinterpret_as_bytes()[0:n]
  let crc = masked_crc(data)
  let raw = self.scratch
  raw.pos = 0
  raw.varint(n)
  compress_fragment(data, 0, n, raw, self.table)
  let compressed = raw.pos < n - n / 8
  let body = if compressed { raw.pos } else { n }
  let out = self.out
  out.byte(if compressed { 0x00 } else { 0x01 })
  out.byte((body + 4) & 0xFF)
  out.byte(((body + 4) >> 8) & 0xFF)
  out.byte((body + 4) >> 16)
  out.byte((crc & 0xFF).reinterpret_as_int())
  out.byte(((crc >> 8) & 0xFF).reinterpret_as_int())
  out.byte(((crc >> 16) & 0xFF).reinterpret_as_int())
  out.byte((crc >> 24).reinterpret_as_int())
  if compressed {
    FixedArray::unsafe_blit(out.data, out.pos, raw.data, 0, raw.pos)
  } else {
    out.data.blit_from_bytesview(out.pos, data)
  }
  out.pos += body
  self.input_len = 0
}
