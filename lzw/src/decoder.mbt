// The streaming LZW decoder.
//
// Codes are read from a bit accumulator that takes the input a byte at a
// time, so a code may span steps. The table holds, for each code, the code
// it extends, its last byte, its first byte and its length; a code's string
// is written backwards from those, straight into the caller's slice when it
// fits, and otherwise into `string`, from which the next steps hand it out.
// Nothing else is held: the table is fixed by the format (4096 codes, or
// 2^max_bits for .Z), and a string is no longer than the table.

///|
priv enum State {
  Header
  Codes
  Done
}

///|
/// A streaming LZW decoder for one of the formats of `Format`.
pub struct Decoder {
  priv format : Format
  priv until : @codec_bytes.Until
  priv allow_missing_end : Bool
  // The format the stream has: `format`, or for .Z the header's.
  priv mut active : Format
  // Whether the stream's first code has been read: .Z's must be a literal,
  // where GIF, TIFF and PDF begin with a clear.
  priv mut begun : Bool
  priv hdr : FixedArray[Byte]
  priv mut hdr_len : Int32
  // Bits taken from the input and not yet read as codes.
  priv mut acc : UInt32
  priv mut nbits : Int32
  // .Z pads a run of codes to a multiple of eight codes at each change of
  // width and each clear: bits still to skip, and codes since the run began.
  priv mut skip : Int32
  priv mut run : Int32
  // The table: for code c, the code it extends, its last and first bytes
  // and its length.
  priv mut prefix : FixedArray[UInt16]
  priv mut suffix : FixedArray[Byte]
  priv mut first : FixedArray[Byte]
  priv mut length : FixedArray[UInt16]
  // Codes defined so far, the current width, and the previous code (-1
  // right after a clear, before the first code).
  priv mut next : Int32
  priv mut bits : Int32
  priv mut prev : Int32
  // A string not handed out yet: `string[spos:slen]`.
  priv mut string : FixedArray[Byte]
  priv mut spos : Int32
  priv mut slen : Int32
  priv mut state : State
  priv mut failure : @codec.CodecError?
  priv mut consumed : Int32
  priv mut produced : Int32
}

///|
/// A decoder at the start of a stream of `format`.
///
/// `until` says where the stream ends: `EndOfInput`, the default, at the
/// end of the input, and bytes after the end code are `TrailingData`;
/// `EndOfMember` right after the end code, consuming nothing past its last
/// byte. .Z has no end code: it ends with the input, and raises
/// `Unsupported` under `EndOfMember`.
///
/// `allow_missing_end` takes the end of the input as the end of a GIF,
/// TIFF or PDF stream that lacks its end code, as many writers leave it
/// out; without it, such a stream raises `Truncated`.
pub fn Decoder::Decoder(
  format : Format,
  until~ : @codec_bytes.Until = EndOfInput,
  allow_missing_end~ : Bool = false,
) -> Decoder {
  let d = {
    format,
    until,
    allow_missing_end,
    active: format,
    begun: false,
    hdr: FixedArray::make(3, b'\x00'),
    hdr_len: 0,
    acc: 0,
    nbits: 0,
    skip: 0,
    run: 0,
    prefix: FixedArray::make(0, 0),
    suffix: FixedArray::make(0, b'\x00'),
    first: FixedArray::make(0, b'\x00'),
    length: FixedArray::make(0, 0),
    next: 0,
    bits: 0,
    prev: -1,
    string: FixedArray::make(0, b'\x00'),
    spos: 0,
    slen: 0,
    state: if format.unix {
      Header
    } else {
      Codes
    },
    failure: None,
    consumed: 0,
    produced: 0,
  }
  if !format.unix {
    d.start(format)
  }
  d
}

///|
/// Allocates the table for `format` (keeping a large enough one) and
/// clears it.
fn Decoder::start(self : Decoder, format : Format) -> Unit {
  self.active = format
  let size = 1 << format.max_bits
  if self.prefix.length() < size {
    self.prefix = FixedArray::make(size, 0)
    self.suffix = FixedArray::make(size, b'\x00')
    self.first = FixedArray::make(size, b'\x00')
    self.length = FixedArray::make(size, 0)
    self.string = FixedArray::make(size + 1, b'\x00')
  }
  for c in 0..<(1 << format.literal_bits) {
    self.suffix[c] = c.to_byte()
    self.first[c] = c.to_byte()
    self.length[c] = 1
  }
  self.clear()
}

///|
/// Back to the first code's state: no codes defined past the literals.
fn Decoder::clear(self : Decoder) -> Unit {
  self.next = self.active.first_code()
  self.bits = self.active.initial_bits()
  self.prev = -1
}

///|
/// Back to the state of a new decoder with the same options; the table's
/// memory is kept.
pub fn Decoder::reset(self : Decoder) -> Unit {
  self.hdr_len = 0
  self.begun = false
  self.acc = 0
  self.nbits = 0
  self.skip = 0
  self.run = 0
  self.spos = 0
  self.slen = 0
  self.failure = None
  self.consumed = 0
  self.produced = 0
  if self.format.unix {
    self.active = self.format
    self.state = Header
  } else {
    self.state = Codes
    self.start(self.format)
  }
}

///|
/// Bytes the decoder holds: the table, 6 bytes a code, and a string of at
/// most the table's length and a byte: 28 KiB for GIF, TIFF and PDF, 448
/// KiB for .Z of 16 bits (`decoder_memory_bound(format)`), allocated for
/// .Z once its header gives its width.
pub fn Decoder::memory_usage(self : Decoder) -> Int32 {
  self.prefix.length() * 2 +
  self.suffix.length() +
  self.first.length() +
  self.length.length() * 2 +
  self.string.length()
}

///|
/// The format the stream has: for .Z, with the header's `max_bits` and
/// `block_mode` once it is read.
pub fn Decoder::stream_format(self : Decoder) -> Format {
  self.active
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
  self.state is Done && self.spos == self.slen && self.failure is None
}

///|
/// Decodes from `input` into `output`. `end` says whether `input` holds the
/// last bytes. Answers `NeedMoreInput` once all of `input` is taken and its
/// output handed out, `NeedMoreOutput` while output waits, and `Done` at
/// the end of the stream. A step that meets an error first hands out the
/// output before it, then raises; after that the decoder raises it again,
/// consuming and writing nothing, until `reset`.
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
  self.run_codes(input, output, end) catch {
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
fn corrupt(message : String) -> @codec.CodecError {
  @codec.CodecError(Corrupt, message)
}

///|
/// Hands out what is left of the current string; false while it does not
/// all fit.
fn Decoder::drain(self : Decoder, output : MutArrayView[Byte]) -> Bool {
  let n = (self.slen - self.spos).min(output.length() - self.produced)
  for i in 0..<n {
    output[self.produced + i] = self.string[self.spos + i]
  }
  self.spos += n
  self.produced += n
  self.spos == self.slen
}

///|
fn Decoder::run_codes(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end : Bool,
) -> @codec_bytes.Status raise @codec.CodecError {
  if self.format.unix && self.until is EndOfMember {
    raise @codec.CodecError(
      Unsupported,
      ".Z has no end code: its end shows only at the end of the input",
    )
  }
  for ;; {
    if !self.drain(output) {
      return NeedMoreOutput
    }
    match self.state {
      Done => {
        if self.until is EndOfInput {
          if self.consumed < input.length() {
            raise @codec.CodecError(TrailingData, "data after the end code")
          }
          // The stream has ended, but the input may not have: bytes in a
          // later step are trailing data.
          if !end {
            return NeedMoreInput
          }
        }
        return Done
      }
      Header => {
        let take = (3 - self.hdr_len).min(input.length() - self.consumed)
        for i in 0..<take {
          self.hdr[self.hdr_len + i] = input[self.consumed + i]
        }
        self.hdr_len += take
        self.consumed += take
        if self.hdr_len < 3 {
          guard end else { return NeedMoreInput }
          raise @codec.CodecError(Truncated, "the input ends inside the header")
        }
        self.header()
      }
      Codes => {
        if self.skip == 0 && self.fast_codes(input, output) {
          continue
        }
        // Skip .Z's padding first.
        while self.skip > 0 {
          if self.nbits == 0 {
            if self.consumed == input.length() {
              guard end else { return NeedMoreInput }
              // The stream may end in its padding.
              self.state = Done
              break
            }
            self.acc = input[self.consumed].to_uint()
            self.nbits = 8
            self.consumed += 1
          }
          // Only .Z pads, and it packs from the least significant bit.
          let n = self.skip.min(self.nbits)
          self.acc = self.acc >> n
          self.nbits -= n
          self.skip -= n
        }
        if self.state is Done {
          continue
        }
        // The width the encoder wrote the code at.
        let encoder_next = self.next + (if self.prev >= 0 { 1 } else { 0 })
        let bits = self.active.width(self.bits, encoder_next)
        if bits != self.bits {
          let old = self.bits
          self.bits = bits
          if self.active.unix && self.pad_run(old) {
            continue
          }
        }
        while self.nbits < self.bits {
          if self.consumed == input.length() {
            guard end else { return NeedMoreInput }
            return self.end_of_input()
          }
          let b = input[self.consumed].to_uint()
          self.consumed += 1
          if self.active.msb_first {
            self.acc = (self.acc << 8) | b
          } else {
            self.acc = self.acc | (b << self.nbits)
          }
          self.nbits += 8
        }
        let code = if self.active.msb_first {
          let c = self.acc >> (self.nbits - self.bits)
          self.acc = self.acc & ((1U << (self.nbits - self.bits)) - 1)
          c
        } else {
          let c = self.acc & ((1U << self.bits) - 1)
          self.acc = self.acc >> self.bits
          c
        }
        self.nbits -= self.bits
        self.run += 1
        self.code(code.reinterpret_as_int(), output)
      }
    }
  }
}

///|
/// .Z's padding where a run of codes of width `old` ends, at a change of
/// width or a clear: the rest of the run's group of eight codes. True when
/// there are bits to skip.
fn Decoder::pad_run(self : Decoder, old : Int32) -> Bool {
  let left = (8 - self.run % 8) % 8
  self.skip = left * old
  self.run = 0
  self.skip > 0
}

///|
/// The end of the input where a code would begin.
fn Decoder::end_of_input(
  self : Decoder,
) -> @codec_bytes.Status raise @codec.CodecError {
  if self.active.unix || self.allow_missing_end {
    // The bits left are padding.
    self.acc = 0
    self.nbits = 0
    self.state = Done
    return Done
  }
  raise @codec.CodecError(Truncated, "the input ends before the end code")
}

///|
/// .Z's header: the magic number, then `max_bits` and block mode.
fn Decoder::header(self : Decoder) -> Unit raise @codec.CodecError {
  guard self.hdr[0] == b'\x1F' && self.hdr[1] == b'\x9D' else {
    raise corrupt("not a .Z stream")
  }
  let flags = self.hdr[2].to_int()
  let max_bits = flags & 0x1F
  if max_bits > 16 {
    raise @codec.CodecError(
      Unsupported,
      "a .Z stream of \{max_bits} bits, over the 16 any compress writes",
    )
  }
  guard max_bits >= 9 else {
    raise corrupt("a .Z stream of \{max_bits} bits, under the 9 it starts at")
  }
  guard max_bits >= 10 else {
    // Readers widen such a stream to 10 bits once its table fills, which
    // compress's encoder does not: no two agree on what it holds.
    raise @codec.CodecError(
      Unsupported,
      "a .Z stream of 9 bits, which compress and gzip read differently from how compress writes it",
    )
  }
  if max_bits > self.format.max_bits {
    let need = (6 << max_bits).to_uint64()
    raise @codec.CodecError(
      LimitExceeded({
        resource: Memory,
        needed: Some(need),
        limit: (6 << self.format.max_bits).to_uint64(),
      }),
      "a .Z stream of \{max_bits} bits, over the \{self.format.max_bits} allowed",
    )
  }
  self.start({ ..self.format, max_bits, block_mode: (flags & 0x80) != 0, })
  self.run = 0
  self.state = Codes
}

///|
/// Takes one code: a clear, the end, or a string to write out.
fn Decoder::code(
  self : Decoder,
  code : Int32,
  output : MutArrayView[Byte],
) -> Unit raise @codec.CodecError {
  let format = self.active
  let first_code = !self.begun
  self.begun = true
  if format.unix && first_code && code >= 256 {
    // compress and gzip refuse a .Z that does not begin with a literal.
    raise corrupt("a .Z whose first code is \{code}, not a literal")
  }
  if format.block_mode && code == format.clear_code() {
    // The clear code ends its run at the width it was read at.
    let old = self.bits
    self.clear()
    if format.unix {
      let _ = self.pad_run(old)
    }
    return
  }
  if code == format.end_code() {
    // The bits left in the last byte are padding.
    self.acc = 0
    self.nbits = 0
    self.state = Done
    return
  }
  if self.prev < 0 {
    guard code < 1 << format.literal_bits else {
      raise corrupt("a first code of \{code}, not a literal")
    }
    self.prev = code
    self.emit(code, output)
    return
  }
  let next = self.next
  if code > next {
    raise corrupt("a code of \{code}, past the table's \{next}")
  }
  // The new code: the previous string and the first byte of this one,
  // which for the code being defined (KwKwK) is the previous string's.
  // A full table defines none; no code of the widest width can then be
  // the one being defined.
  if next < format.table_limit() {
    let p = self.prev
    self.prefix[next] = p.to_uint16()
    self.first[next] = self.first[p]
    self.length[next] = (self.length[p].to_int() + 1).to_uint16()
    self.suffix[next] = if code == next {
      self.first[p]
    } else {
      self.first[code]
    }
    self.next = next + 1
  }
  self.prev = code
  self.emit(code, output)
}

///|
/// Writes code `code`'s string: into the caller's slice when it fits,
/// otherwise into `string`, to be handed out.
fn Decoder::emit(
  self : Decoder,
  code : Int32,
  output : MutArrayView[Byte],
) -> Unit {
  let n = self.length[code].to_int()
  if n <= output.length() - self.produced {
    let mut c = code
    for i = self.produced + n - 1; i >= self.produced; i = i - 1 {
      output[i] = self.suffix[c]
      c = self.prefix[c].to_int()
    }
    self.produced += n
  } else {
    let mut c = code
    for i = n - 1; i >= 0; i = i - 1 {
      self.string[i] = self.suffix[c]
      c = self.prefix[c].to_int()
    }
    self.spos = 0
    self.slen = n
  }
}

///|
/// Decodes codes in a tight loop while the input holds the bytes of a code
/// and each code's string fits the caller's slice: the state stays in
/// locals, committed when it stops. Clears, the end code, the first code
/// after a clear, codes past the table, strings that do not fit, and .Z's
/// changes of width go to `code` and the step's loop, after a commit. True
/// when it took any code.
fn Decoder::fast_codes(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
) -> Bool raise @codec.CodecError {
  let format = self.active
  let msb = format.msb_first
  let limit = format.table_limit()
  let prefix = self.prefix
  let suffix = self.suffix
  let first = self.first
  let length = self.length
  let n = input.length()
  let mut acc = self.acc
  let mut nbits = self.nbits
  let mut bits = self.bits
  let mut next = self.next
  let mut prev = self.prev
  let mut pos = self.consumed
  let mut out = self.produced
  let mut run = self.run
  let mut took = false
  // Three bytes hold any code of up to 16 bits beyond the bits held.
  // Compared as a difference: `pos + 3` could overflow near 2^31.
  while prev >= 0 && n - pos >= 3 {
    let w = format.width(bits, next + 1)
    if w != bits {
      if format.unix {
        break
      }
      bits = w
    }
    while nbits < bits {
      let b = input.unsafe_get(pos).to_uint()
      pos += 1
      if msb {
        acc = (acc << 8) | b
      } else {
        acc = acc | (b << nbits)
      }
      nbits += 8
    }
    let code = if msb {
      let c = acc >> (nbits - bits)
      acc = acc & ((1U << (nbits - bits)) - 1)
      c.reinterpret_as_int()
    } else {
      let c = acc & ((1U << bits) - 1)
      acc = acc >> bits
      c.reinterpret_as_int()
    }
    nbits -= bits
    run += 1
    took = true
    let len = if code < next {
      length[code].to_int()
    } else {
      length[prev].to_int() + 1
    }
    if code > next ||
      (format.block_mode && code == format.clear_code()) ||
      code == format.end_code() ||
      len > output.length() - out {
      // The code and its state go to `code`, which handles or refuses it.
      self.commit(acc, nbits, bits, next, prev, pos, out, run)
      self.code(code, output)
      return true
    }
    if next < limit {
      prefix[next] = prev.to_uint16()
      first[next] = first[prev]
      length[next] = (length[prev].to_int() + 1).to_uint16()
      suffix[next] = if code == next { first[prev] } else { first[code] }
      next += 1
    }
    // Codes and the codes they extend are under `next`, within the table;
    // the string fits `output` from `out`, as checked above.
    let mut c = code
    for i = out + len - 1; i >= out; i = i - 1 {
      output.unsafe_set(i, suffix.unsafe_get(c))
      c = prefix.unsafe_get(c).to_int()
    }
    out += len
    prev = code
  }
  self.commit(acc, nbits, bits, next, prev, pos, out, run)
  took
}

///|
/// Stores the state `fast_codes` kept in locals.
fn Decoder::commit(
  self : Decoder,
  acc : UInt32,
  nbits : Int32,
  bits : Int32,
  next : Int32,
  prev : Int32,
  pos : Int32,
  out : Int32,
  run : Int32,
) -> Unit {
  self.acc = acc
  self.nbits = nbits
  self.bits = bits
  self.next = next
  self.prev = prev
  self.consumed = pos
  self.produced = out
  self.run = run
}
