// The streaming encoder.
//
// Input is copied into `data`, a buffer that keeps the window of past input
// (for backward references) and the input not encoded yet, at most one
// meta-block of it. A full meta-block's worth is encoded as soon as it is
// there; `Flush` and `Finish` encode whatever is buffered. Compressed bytes
// wait in the bit writer until the caller's buffer takes them, and no more
// input is taken while they wait: memory stays bounded whatever the caller
// passes. The step model follows moonbit-community/flate's `Deflater`.

///|
/// What `Encoder::step` should do once it has taken all of its input.
pub(all) enum EncodeAction {
  /// Only take input.
  Continue
  /// Compress everything buffered and pad to a byte boundary, so that the
  /// output so far decodes to the input so far; the stream continues.
  Flush
  /// Compress everything buffered and end the stream.
  Finish
} derive(Eq, Debug)

///|
pub extend EncodeAction with Eq::{equal, not_equal}

///|
pub extend EncodeAction with @debug.Debug::{to_repr}

///|
/// The first allocation of the input buffer; it doubles as input grows.
const INITIAL_BUFFER : Int32 = 1024

///|
/// A streaming Brotli encoder (RFC 7932): greedy LZ77 with one prefix code
/// per category, about the ratio of gzip. Feed it input in chunks of any
/// size with `step` and collect output in slices of any size. It keeps the
/// window of past input (`1 << window_bits` bytes, and no more than the
/// input so far) plus at most a meta-block (64 KiB) of input and its
/// output, and fixed-size tables.
pub struct Encoder {
  priv window_bits : Int32
  // The longest distance: the window less 16 bytes (section 9.1).
  priv max_distance : Int32
  // The input buffer: `data[0..data_len)` is past input (the window) up to
  // `block_start`, then input not encoded yet. It grows up to `data_max`,
  // then slides down.
  priv mut data : FixedArray[Byte]
  priv mut data_len : Int32
  priv mut block_start : Int32
  priv data_max : Int32
  priv matcher : @lz77.Matcher
  // The distance of the latest `longest_match`.
  priv mut found_dist : Int32
  priv meta_block : MetaBlock
  // The last four distances, as the decoder keeps them.
  priv dist_ring : FixedArray[Int32]
  priv mut dist_ring_index : Int32
  // Output: complete bytes of `writer` from `drained` wait for the caller.
  priv writer : BitPacker
  priv mut drained : Int32
  priv mut header_written : Bool
  priv mut flush_requested : Bool
  priv mut finish_requested : Bool
  priv mut emitted_final : Bool
  priv mut done : Bool
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
}

///|
/// An encoder at the start of a stream, with a window of
/// `1 << window_bits` bytes (clamped to 10..24). The default 22 is the
/// reference encoder's; a decoder needs up to that much memory.
pub fn Encoder::Encoder(window_bits~ : Int32 = 22) -> Encoder {
  let window_bits = window_bits.clamp(min=10, max=24)
  let window = 1 << window_bits
  // Room to slide by at least a quarter window (or a meta-block) at a time.
  let slack = (window >> 2).max(BLOCK_SIZE)
  {
    window_bits,
    max_distance: window - 16,
    data: FixedArray::make(0, b'\x00'),
    data_len: 0,
    block_start: 0,
    data_max: window - 16 + slack + BLOCK_SIZE,
    matcher: @lz77.Matcher(hash_bits=window_bits.min(15)),
    found_dist: 0,
    meta_block: MetaBlock::new(),
    dist_ring: [16, 15, 11, 4],
    dist_ring_index: 0,
    writer: BitPacker::new(),
    drained: 0,
    header_written: false,
    flush_requested: false,
    finish_requested: false,
    emitted_final: false,
    done: false,
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Starts a new stream, keeping the tables' memory. The input buffer is
/// released.
pub fn Encoder::reset(self : Encoder) -> Unit {
  self.data = FixedArray::make(0, b'\x00')
  self.data_len = 0
  self.block_start = 0
  self.matcher.reset()
  self.dist_ring[0] = 16
  self.dist_ring[1] = 15
  self.dist_ring[2] = 11
  self.dist_ring[3] = 4
  self.dist_ring_index = 0
  self.writer.clear()
  self.writer.acc = 0
  self.writer.nbits = 0
  self.drained = 0
  self.header_written = false
  self.flush_requested = false
  self.finish_requested = false
  self.emitted_final = false
  self.done = false
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// Whether the stream has ended and all its output has been handed out.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.done
}

///|
/// Input bytes the latest `step` took.
pub fn Encoder::last_consumed(self : Encoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote.
pub fn Encoder::last_produced(self : Encoder) -> Int32 {
  self.step_produced
}

///|
/// Compresses from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used. Input that was not taken
/// (when the output is full) must be passed again, with the same action.
///
/// `action` applies once all of `input` is taken: `Flush` makes the output
/// so far decode to the input so far, `Finish` ends the stream. Both stay
/// in effect while the step answers `NeedMoreOutput`. Status: `NeedMoreInput`
/// once everything is taken and its output handed out (a `Flush` is then
/// complete), `NeedMoreOutput` while output waits, `Done` once the stream
/// has ended and been handed out; after that, steps take no input and
/// answer `Done`.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  action~ : EncodeAction = Continue,
) -> Status {
  self.step_with(input, output, None, action)
}

///|
/// `step` into a whole `FixedArray`, with bulk copies.
pub fn Encoder::step_into(
  self : Encoder,
  input : BytesView,
  output : FixedArray[Byte],
  action~ : EncodeAction = Continue,
) -> Status {
  self.step_with(input, output.mut_view(), Some(output), action)
}

///|
fn Encoder::step_with(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  action : EncodeAction,
) -> Status {
  self.step_consumed = 0
  self.step_produced = 0
  if self.done {
    return Done
  }
  if input.length() == 0 {
    self.latch(action)
  }
  let mut consumed = 0
  let mut produced = 0
  for ;; {
    produced = self.drain(output, fixed_output, produced)
    if self.drained < self.writer.len {
      return self.finish_step(NeedMoreOutput, consumed, produced)
    }
    self.writer.clear()
    self.drained = 0
    if self.emitted_final {
      self.done = true
      return self.finish_step(Done, consumed, produced)
    }
    if self.finish_requested {
      self.emit_final()
      continue
    }
    if self.flush_requested {
      self.emit_flush()
      continue
    }
    let buffered = self.data_len - self.block_start
    if buffered == BLOCK_SIZE {
      self.write_header()
      self.encode_block(self.block_start, self.data_len, false)
      self.block_start = self.data_len
      continue
    }
    if consumed == input.length() {
      return self.finish_step(NeedMoreInput, consumed, produced)
    }
    let take = (input.length() - consumed).min(BLOCK_SIZE - buffered)
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
/// Takes `action` once its input is all taken; a finished stream takes no
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
  let n = (self.writer.len - self.drained).min(output.length() - pos)
  guard n > 0 else { return pos }
  let buf = self.writer.buf
  match fixed_output {
    Some(out) => FixedArray::unsafe_blit(out, pos, buf, self.drained, n)
    None =>
      for i in 0..<n {
        output[pos + i] = buf[self.drained + i]
      }
  }
  self.drained += n
  pos + n
}

///|
/// Copies `bytes` (at most what fills a meta-block) after the buffered
/// input, growing or sliding the buffer.
fn Encoder::append(self : Encoder, bytes : BytesView) -> Unit {
  let n = bytes.length()
  if self.data_len + n > self.data.length() &&
    self.data.length() < self.data_max {
    let mut size = self.data.length().max(INITIAL_BUFFER)
    while size < self.data_len + n {
      size = size * 2
    }
    let grown = FixedArray::make(size.min(self.data_max), b'\x00')
    FixedArray::unsafe_blit(grown, 0, self.data, 0, self.data_len)
    self.data = grown
  }
  if self.data_len + n > self.data.length() {
    // Keep the window before the input not encoded yet. `data_max` leaves
    // room for at least a meta-block, so the shift is at least that.
    let shift = self.block_start - self.max_distance
    FixedArray::unsafe_blit(
      self.data,
      0,
      self.data,
      shift,
      self.data_len - shift,
    )
    self.data_len -= shift
    self.block_start -= shift
    self.matcher.slide(shift)
  }
  self.data.blit_from_bytesview(self.data_len, bytes)
  self.data_len += n
}

///|
/// The stream header: WBITS (section 9.1), before the first meta-block.
fn Encoder::write_header(self : Encoder) -> Unit {
  guard !self.header_written else { return }
  self.header_written = true
  let w = self.writer
  let wbits = self.window_bits
  if wbits == 16 {
    w.write(1, 0)
  } else if wbits == 17 {
    w.write(7, 1)
  } else if wbits > 17 {
    w.write(4, 1 | ((wbits - 17) << 1))
  } else {
    w.write(7, 1 | ((wbits - 8) << 4))
  }
}

///|
/// Encodes the buffered input and pads to a byte boundary with an empty
/// metadata meta-block, as the reference encoder's flush does.
fn Encoder::emit_flush(self : Encoder) -> Unit {
  self.flush_requested = false
  self.write_header()
  if self.block_start < self.data_len {
    self.encode_block(self.block_start, self.data_len, false)
    self.block_start = self.data_len
  }
  if self.writer.nbits > 0 {
    // ISLAST 0, MNIBBLES 0 (a metadata block), reserved 0, MSKIPBYTES 0.
    self.writer.write(6, 0b000110)
    self.writer.align()
  }
}

///|
/// Encodes the buffered input as the last meta-block and pads the stream.
fn Encoder::emit_final(self : Encoder) -> Unit {
  self.write_header()
  if self.block_start < self.data_len {
    self.encode_block(self.block_start, self.data_len, true)
    self.block_start = self.data_len
  } else {
    // ISLAST and ISLASTEMPTY.
    self.writer.write(2, 3)
  }
  self.writer.align()
  self.emitted_final = true
}
