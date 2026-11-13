// The streaming encoder.
//
// Input is copied into `data`, which holds the block not encoded yet, at
// most Block_Maximum_Size (128 KiB). A block ends only when it is full and
// more input comes, or at `Flush` or `Finish`: never at the boundary of a
// step, so that the output does not depend on how the input is split. A
// full block waits for the next byte because only then is it known not to
// be the frame's last. Encoded bytes wait in the bit writer until the
// caller's buffer takes them, and no more input is taken while they wait:
// memory stays bounded whatever the caller passes.

///|
/// The first allocation of the input buffer; it doubles as input grows, up
/// to a block.
const INITIAL_BUFFER : Int32 = 1024

///|
/// A streaming Zstandard encoder (RFC 8878). Feed it input in chunks of any
/// size with `step` and collect output in slices of any size. It writes one
/// frame: Raw, RLE or Compressed blocks of at most 128 KiB, whichever is
/// smallest, and the XXH64 content checksum unless asked not to.
///
/// Levels 1..4 select fast or double-fast from their size-class parameters.
/// Later strategies temporarily use the nearest double-fast row.
pub struct Encoder {
  priv checksum : Bool
  priv content_size : Int64?
  // The level's parameters. The frame's window is `params.window_log`, or
  // the content size of a single-segment frame.
  priv params : Params
  priv single_segment : Bool
  priv block_max : Int32
  // The input of the block not encoded yet: `data[0..data_len)`.
  priv mut data : FixedArray[Byte]
  priv mut data_len : Int32
  priv literals : LiteralsWriter
  priv matcher : Matcher
  priv sequences : @seqenc.Block
  priv sequence_writer : @seqenc.Writer
  priv sequence_bits : @bits.BitPacker
  priv mut sequence_copy : FixedArray[Byte]
  priv hash : @xxhash.Xxh64
  // Input taken so far in the frame.
  priv mut total_in : Int64
  // Output: complete bytes of `writer` wait for the caller.
  priv writer : @bits.BitPacker
  priv mut header_written : Bool
  priv mut flush_requested : Bool
  priv mut finish_requested : Bool
  priv mut emitted_final : Bool
  priv mut done : Bool
  priv mut failure : @codec.CodecError?
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
}

///|
/// An encoder at the start of a frame.
///
/// `level` is zstd's compression level: 1 to 12, 3 by default as in zstd.
/// Levels 13 to 22 are not implemented yet and act as 12; levels below 1,
/// zstd's negative (faster) levels and its level 0, act as 1.
///
/// `checksum` adds the frame's content checksum, the low 32 bits of the
/// XXH64 of the input, as zstd does by default.
///
/// `content_size`, when given, is written in the frame header as
/// Frame_Content_Size, and the input must then be exactly that long:
/// `step` raises `ChecksumMismatch` once it has more, or at `Finish` when
/// it has less. Like zstd, the encoder then picks its parameters from the
/// size, and a frame that fits its window is written single-segment, so a
/// decoder reserves no more than the content. A negative `content_size`
/// counts as not given.
pub fn Encoder::Encoder(
  level~ : Int32 = DEFAULT_LEVEL,
  checksum~ : Bool = true,
  content_size? : Int64,
) -> Encoder {
  let level = level.clamp(min=1, max=MAX_LEVEL)
  let content_size = match content_size {
    Some(size) if size >= 0 => Some(size)
    _ => None
  }
  let params = encoder_params(level, content_size)
  let window_log = params.window_log
  let single_segment = content_size is Some(size) && size <= 1L << window_log
  let block_max = match content_size {
    Some(size) if single_segment => size.min(MAX_BLOCK_SIZE.to_int64()).to_int()
    _ => (1 << window_log).min(MAX_BLOCK_SIZE)
  }
  {
    checksum,
    content_size,
    params,
    single_segment,
    block_max,
    data: FixedArray::make(0, b'\x00'),
    data_len: 0,
    literals: LiteralsWriter::new(),
    matcher: Matcher::new(params),
    sequences: @seqenc.Block(),
    sequence_writer: @seqenc.Writer(),
    sequence_bits: @bits.BitPacker(),
    sequence_copy: [],
    hash: @xxhash.Xxh64(),
    total_in: 0,
    writer: @bits.BitPacker(),
    header_written: false,
    flush_requested: false,
    finish_requested: false,
    emitted_final: false,
    done: false,
    failure: None,
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Starts a new frame with the same options, keeping the tables' memory.
/// The input buffer is released.
pub fn Encoder::reset(self : Encoder) -> Unit {
  self.data = FixedArray::make(0, b'\x00')
  self.data_len = 0
  self.hash.reset()
  self.matcher.reset()
  self.sequence_writer.reset()
  self.literals.reset()
  self.total_in = 0
  self.writer.reset()
  self.header_written = false
  self.flush_requested = false
  self.finish_requested = false
  self.emitted_final = false
  self.done = false
  self.failure = None
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// Whether the frame has ended and all its output has been handed out.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.done
}

///|
/// Input bytes the latest `step` took.
pub fn Encoder::last_consumed(self : Encoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote, a step that raised included.
pub fn Encoder::last_produced(self : Encoder) -> Int32 {
  self.step_produced
}

///|
/// Bytes the encoder holds in buffers that grow with the stream: the input
/// buffer (at most one 128 KiB block), the output waiting for the caller,
/// match window and hash, sequence storage, and entropy coding scratch.
/// Bounds for each are in RESOURCE_BOUNDS.md. `reset` releases the input
/// and match window buffers.
pub fn Encoder::memory_usage(self : Encoder) -> Int32 {
  self.data.length() +
  self.writer.capacity() +
  self.literals.memory_usage() +
  self.matcher.memory_usage() +
  self.sequences.memory_usage() +
  self.sequence_writer.memory_usage() +
  self.sequence_bits.capacity() +
  self.sequence_copy.length()
}

///|
/// Compresses from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used. Input that was not taken
/// (when the output is full) must be passed again, with the same action.
///
/// `action` applies once all of `input` is taken: `Continue` only takes
/// input, `Flush` ends the block in progress, so that the output so far
/// decodes to the input so far without ending the frame, and `Finish` ends
/// the frame. Both stay in effect while the step answers `NeedMoreOutput`.
/// A `Flush` with no input since the last one writes nothing. Status:
/// `NeedMoreInput` once everything is taken and its output handed out (a
/// `Flush` is then complete), `NeedMoreOutput` while output waits, `Done`
/// once the frame has ended and been handed out; after that, steps take no
/// input and answer `Done`.
///
/// Raises only when the encoder was given `content_size` and the input
/// does not match it: `ChecksumMismatch`, once the input passes it (the
/// bytes up to it are taken as with `Continue`, and the output they decide
/// is handed out first, so that the output before the error does not depend
/// on how input and output are split) or at `Finish` when it falls short. The error sticks: later steps raise it again, taking and writing
/// nothing, until `reset`.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  action~ : EncodeAction,
) -> Status raise @codec.CodecError {
  self.step_with(input, output, None, action)
}

///|
/// `step` into a whole `FixedArray`, with bulk copies.
pub fn Encoder::step_into(
  self : Encoder,
  input : BytesView,
  output : FixedArray[Byte],
  action~ : EncodeAction,
) -> Status raise @codec.CodecError {
  self.step_with(input, output.mut_view(), Some(output), action)
}

///|
fn Encoder::step_with(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  action : EncodeAction,
) -> Status raise @codec.CodecError {
  self.step_consumed = 0
  self.step_produced = 0
  if self.failure is Some(err) {
    raise err
  }
  if self.done {
    return Done
  }
  // Input past the content size given: the bytes up to it are taken as
  // with `Continue`, and what they decide is handed out, before the error.
  // So the output before it is the same however input and output are
  // split: that of the first `content_size` bytes under `Continue`.
  let (input, action, over) = match self.content_size {
    Some(size) if !self.finish_requested &&
      self.total_in + input.length().to_int64() > size =>
      (input[:(size - self.total_in).to_int()], EncodeAction::Continue, true)
    _ => (input, action, false)
  }
  if input.length() == 0 {
    self.latch(action)
  }
  let mut consumed = 0
  let mut produced = 0
  for ;; {
    produced = self.drain(output, fixed_output, produced)
    if self.writer.pending() > 0 {
      return self.finish_step(NeedMoreOutput, consumed, produced)
    }
    if self.emitted_final {
      self.done = true
      return self.finish_step(Done, consumed, produced)
    }
    if self.finish_requested {
      if self.content_size is Some(size) && self.total_in < size {
        self.step_consumed = consumed
        self.step_produced = produced
        self.fail(
          "the input ends at \{self.total_in} bytes, short of the content size given, \{size}",
        )
      }
      self.emit_final()
      continue
    }
    if self.flush_requested {
      self.emit_flush()
      continue
    }
    if consumed == input.length() {
      if over {
        self.step_consumed = consumed
        self.step_produced = produced
        self.fail(
          "the input is longer than the content size given, \{self.total_in} bytes",
        )
      }
      return self.finish_step(NeedMoreInput, consumed, produced)
    }
    // A full block is known not to be the last once more input comes.
    if self.data_len == self.block_max {
      self.write_header()
      self.encode_block(false)
      continue
    }
    let take = (input.length() - consumed).min(self.block_max - self.data_len)
    self.append(input[consumed:consumed + take])
    consumed += take
    if consumed == input.length() {
      self.latch(action)
    }
  }
}

///|
fn Encoder::finish_step(
  self : Encoder,
  status : Status,
  consumed : Int32,
  produced : Int32,
) -> Status {
  self.step_consumed = consumed
  self.step_produced = produced
  status
}

///|
/// Records the content size error and raises it.
fn Encoder::fail(
  self : Encoder,
  message : String,
) -> Unit raise @codec.CodecError {
  let err = @codec.CodecError(ChecksumMismatch, message)
  self.failure = Some(err)
  raise err
}

///|
/// Takes `action` once its input is all taken; a finished frame takes no
/// more requests.
fn Encoder::latch(self : Encoder, action : EncodeAction) -> Unit {
  guard !self.finish_requested else { return }
  match action {
    Continue => ()
    Flush => self.flush_requested = true
    Finish => self.finish_requested = true
  }
}

///|
/// Hands out waiting output into `output` from `pos`; the new position.
fn Encoder::drain(
  self : Encoder,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  pos : Int32,
) -> Int32 {
  match fixed_output {
    Some(out) => self.writer.drain_into(out, pos)
    None => self.writer.drain(output, pos)
  }
}

///|
/// Copies `bytes` (at most what fills a block) after the buffered input,
/// growing the buffer.
fn Encoder::append(self : Encoder, bytes : BytesView) -> Unit {
  let n = bytes.length()
  if self.data_len + n > self.data.length() {
    let mut size = self.data.length().max(INITIAL_BUFFER)
    while size < self.data_len + n {
      size = size * 2
    }
    let grown = FixedArray::make(size.min(self.block_max), b'\x00')
    FixedArray::unsafe_blit(grown, 0, self.data, 0, self.data_len)
    self.data = grown
  }
  self.data.blit_from_bytesview(self.data_len, bytes)
  self.data_len += n
  self.total_in += n.to_int64()
}

///|
/// Ends the block in progress, if there is one.
fn Encoder::emit_flush(self : Encoder) -> Unit {
  self.flush_requested = false
  if self.data_len > 0 {
    self.write_header()
    self.encode_block(false)
  }
}

///|
/// Encodes the buffered input as the last block (an empty raw block when
/// there is none, as zstd writes for an empty frame or one that ends on a
/// block boundary), then the content checksum.
fn Encoder::emit_final(self : Encoder) -> Unit {
  self.write_header()
  self.encode_block(true)
  if self.checksum {
    let digest = self.hash.digest()
    self.writer.write(32, digest.to_uint().reinterpret_as_int())
  }
  self.emitted_final = true
}

///|
/// The frame header (RFC 8878 section 3.1.1.1), before the first block.
fn Encoder::write_header(self : Encoder) -> Unit {
  guard !self.header_written else { return }
  self.header_written = true
  write_frame_header(
    self.writer,
    self.content_size,
    self.params.window_log,
    self.single_segment,
    self.checksum,
  )
}

///|
/// Encodes `data[0..data_len)` as one block, `last` or not, and empties the
/// buffer.
fn Encoder::encode_block(self : Encoder, last : Bool) -> Unit {
  let n = self.data_len
  self.hash.update(self.data, 0, n)
  self.matcher.find(self.data, n, self.sequence_writer.repeats, self.sequences)
  self.write_matched_block(n, last)
  self.data_len = 0
}

///|
/// Compresses through `Encoder::step`. Raises only for an input that does
/// not match the `content_size` given.
pub impl @codec_bytes.Encode for Encoder with fn step(
  self,
  input,
  output,
  action~,
) {
  self.step(input, output, action~)
}

///|
/// Same as `Encoder::last_consumed`: input bytes the last step consumed.
pub impl @codec_bytes.Encode for Encoder with fn last_consumed(self) {
  self.last_consumed()
}

///|
/// Same as `Encoder::last_produced`: output bytes the last step wrote.
pub impl @codec_bytes.Encode for Encoder with fn last_produced(self) {
  self.last_produced()
}

///|
/// Same as `Encoder::reset`: back to the state of a new encoder with the same options.
pub impl @codec_bytes.Encode for Encoder with fn reset(self) {
  self.reset()
}

///|
/// Same as `Encoder::memory_usage`: bytes allocated for the current stream.
pub impl @codec_bytes.Encode for Encoder with fn memory_usage(self) {
  self.memory_usage()
}
