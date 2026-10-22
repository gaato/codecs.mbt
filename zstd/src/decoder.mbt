// The streaming decoder.
//
// Suspension model: zstd is byte-aligned outside compressed blocks, so the
// decoder works in coarse units. Header fields gather in `hdr` (at most 14
// bytes) and a compressed block gathers whole in `block` (at most 128 KiB)
// before it is decoded in one go: its bitstreams are read backwards from its
// end. Raw and RLE blocks stream straight to the window. A unit takes every
// input byte it is offered, so the caller may drop each chunk; when the
// input runs out a unit raises `NeedInput`.
//
// Decoded bytes go to the window, a ring of at most `Window_Size` bytes,
// and are copied out to the caller's buffer, so output can be handed out in
// slices of any size. A compressed block is decoded only once all earlier
// output is handed out, so its output never overwrites bytes still pending.
// An error is kept in `failure` and raised once the output decoded before it
// is handed out, so that it comes after the same output whatever the split.

///|
priv enum State {
  Magic
  SkippableSize
  SkippableData
  FrameHeader
  BlockHeader
  RawBlock
  RleByte
  RleRun
  CompressedBlock
  Checksum
  Done
}

///|
/// The zstd frame magic number.
const FRAME_MAGIC : UInt32 = 0xFD2FB528

///|
/// The largest block a frame may hold, compressed or not.
const MAX_BLOCK_SIZE : Int32 = 1 << 17

///|
/// The first window allocation; it doubles as output grows, up to the
/// frame's window.
const INITIAL_WINDOW : Int32 = 1024

///|
/// A streaming Zstandard decoder (RFC 8878). Feed it input in chunks of any
/// size with `step` and collect output in slices of any size; it keeps the
/// window (no more than a frame's `Window_Size`, and no more than its output
/// so far), one compressed block and fixed-size tables, never the whole
/// input or output.
pub struct Decoder {
  priv max_window_bits : Int32
  priv until : @codec_bytes.Until
  // The input of the current step.
  priv mut view : BytesView
  priv mut in_pos : Int32
  // Header bytes gathered so far.
  priv hdr : FixedArray[Byte]
  priv mut hdr_len : Int32
  // The caller's output buffer for the current step.
  priv mut out : MutArrayView[Byte]
  priv mut fixed_out : FixedArray[Byte]?
  priv mut out_pos : Int32
  priv empty_out : FixedArray[Byte]
  // The window: a ring of up to `ring_max` bytes, allocated as output
  // grows; it wraps only once it is `ring_max` long. `pending` bytes before
  // `wpos` are not handed out yet; `filled` is how far back an offset may
  // reach, min(frame output, window).
  priv mut ring : FixedArray[Byte]
  priv mut ring_max : Int32
  priv mut wpos : Int32
  priv mut pending : Int32
  priv mut filled : Int32
  // Stream state.
  priv mut state : State
  priv mut frames : Int32
  priv mut failure : @codec.CodecError?
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
  // The current frame.
  priv mut new_frame : Bool
  priv mut window : Int32
  priv mut block_max : Int32
  priv mut has_checksum : Bool
  priv mut content_size : UInt64?
  priv mut frame_out : UInt64
  priv xxh : @xxhash.Xxh64
  // The current block.
  priv mut last_block : Bool
  priv mut block_size : Int32
  priv mut remaining : Int64
  priv mut rle_byte : Byte
  priv mut block : FixedArray[Byte]
  priv mut block_len : Int32
  priv mut block_out : Int32
  // Compressed blocks: literals, the tables kept from block to block, and
  // the repeat offsets.
  priv mut literals : FixedArray[Byte]
  priv mut literals_len : Int32
  priv huffman : Huffman
  priv mut huffman_valid : Bool
  priv ll_store : Fse
  priv of_store : Fse
  priv ml_store : Fse
  priv mut ll_table : Fse?
  priv mut of_table : Fse?
  priv mut ml_table : Fse?
  priv scratch : FseScratch
  priv rep : FixedArray[Int32]
}

///|
/// A decoder at the start of a stream. It refuses, with
/// `LimitExceeded({ resource: Memory, .. })`, a frame whose `Window_Size`
/// exceeds `1 << max_window_bits` bytes (the window memory it would need).
/// The default 27 is the reference decoder's default limit; RFC 9659 asks
/// HTTP clients to accept 23 (8 MiB). Values are clamped to 10..30.
///
/// `until` says where the stream ends. `EndOfInput`, the default, decodes
/// every frame up to the end of the input. `EndOfMember` stops right after
/// the first frame, a skippable frame included, and consumes nothing past
/// it, so that `input[last_consumed():]` is what follows.
pub fn Decoder::Decoder(
  max_window_bits~ : Int32 = 27,
  until~ : @codec_bytes.Until = EndOfInput,
) -> Decoder {
  let empty_out = FixedArray::make(0, b'\x00')
  {
    max_window_bits: max_window_bits.clamp(min=10, max=30),
    until,
    view: b""[:],
    in_pos: 0,
    hdr: FixedArray::make(14, b'\x00'),
    hdr_len: 0,
    out: empty_out.mut_view(),
    fixed_out: None,
    out_pos: 0,
    empty_out,
    ring: FixedArray::make(0, b'\x00'),
    ring_max: 0,
    wpos: 0,
    pending: 0,
    filled: 0,
    state: Magic,
    frames: 0,
    failure: None,
    step_consumed: 0,
    step_produced: 0,
    new_frame: false,
    window: 0,
    block_max: 0,
    has_checksum: false,
    content_size: None,
    frame_out: 0,
    xxh: @xxhash.Xxh64(),
    last_block: false,
    block_size: 0,
    remaining: 0,
    rle_byte: b'\x00',
    block: FixedArray::make(0, b'\x00'),
    block_len: 0,
    block_out: 0,
    literals: FixedArray::make(0, b'\x00'),
    literals_len: 0,
    huffman: Huffman::new(),
    huffman_valid: false,
    ll_store: Fse::new(9),
    of_store: Fse::new(8),
    ml_store: Fse::new(9),
    ll_table: None,
    of_table: None,
    ml_table: None,
    scratch: FseScratch::new(),
    rep: [1, 4, 8],
  }
}

///|
/// Starts a new stream with the same options, keeping the tables' memory.
/// The window and the block buffers are released.
pub fn Decoder::reset(self : Decoder) -> Unit {
  self.release_step()
  self.hdr_len = 0
  self.ring = FixedArray::make(0, b'\x00')
  self.ring_max = 0
  self.wpos = 0
  self.pending = 0
  self.filled = 0
  self.state = Magic
  self.frames = 0
  self.failure = None
  self.step_consumed = 0
  self.step_produced = 0
  self.new_frame = false
  self.block = FixedArray::make(0, b'\x00')
  self.block_len = 0
  self.literals = FixedArray::make(0, b'\x00')
  self.literals_len = 0
}

///|
/// Bytes held in buffers sized by the stream: the window, the compressed
/// block and its literals. The fixed-size tables are not counted. At most
/// `(1 << max_window_bits) + 2 * 128 KiB`; the window is released when a
/// frame needs a smaller one, so it may drop between frames.
pub fn Decoder::memory_usage(self : Decoder) -> Int32 {
  self.ring.length() + self.block.length() + self.literals.length()
}

///|
/// Whether the stream has ended and all its output has been handed out.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  self.state is Done && self.pending == 0
}

///|
/// Input bytes the latest `step` accepted: all of them on `NeedMoreInput`.
/// A step that raised accepted the bytes up to the error; for
/// `TrailingData`, exactly up to the end of the stream, or none if the
/// stream ended before this step's input.
pub fn Decoder::last_consumed(self : Decoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote, a step that raised included: the
/// output before the error.
pub fn Decoder::last_produced(self : Decoder) -> Int32 {
  self.step_produced
}

///|
/// Decodes from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used.
///
/// A stream is one or more frames, and nothing marks its last one, so pass
/// `end=true` once `input` holds the last bytes and `end=false` before: the
/// stream then ends after the frame in progress, and a stream cut short
/// raises `Truncated`. Without `end`, the decoder answers `NeedMoreInput`
/// between frames. Bytes after the last frame that start no frame raise
/// `TrailingData`. Under `until=EndOfMember` the stream ends after its first
/// frame, whatever `end` says.
///
/// An error comes after all the output before it: when `output` fills
/// first, the step answers `NeedMoreOutput` and a later one hands out the
/// rest and raises. After an error the decoder raises it again, consuming
/// and writing nothing, until `reset`.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_with(input, output, None, end~)
}

///|
/// `step` into a whole `FixedArray`, with bulk copies.
pub fn Decoder::step_into(
  self : Decoder,
  input : BytesView,
  output : FixedArray[Byte],
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_with(input, output.mut_view(), Some(output), end~)
}

///|
fn Decoder::step_with(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_consumed = 0
  self.step_produced = 0
  self.view = input
  self.in_pos = 0
  self.out = output
  self.fixed_out = fixed_output
  self.out_pos = 0
  if self.failure is Some(err) {
    // Output from before the error that did not fit yet.
    self.drain()
    return self.finish_failed(err)
  }
  let status = self.run() catch { err => return self.fail(err) }
  let status = match status {
    NeedMoreInput if end =>
      if !(self.state is Magic && self.hdr_len == 0) {
        return self.fail(
          CodecError(Truncated, "the stream ends inside a frame"),
        )
      } else if self.frames == 0 {
        return self.fail(CodecError(Truncated, "the stream holds no frame"))
      } else {
        self.state = Done
        Status::Done
      }
    status => status
  }
  self.drain()
  self.finish_step(if self.pending > 0 { NeedMoreOutput } else { status })
}

///|
fn Decoder::finish_step(self : Decoder, status : Status) -> Status {
  self.step_consumed = self.in_pos
  self.step_produced = self.out_pos
  self.release_step()
  status
}

///|
/// Records a terminal error, hands out the output before it, and raises it
/// once that is all out.
fn Decoder::fail(
  self : Decoder,
  err : @codec.CodecError,
) -> Status raise @codec.CodecError {
  self.failure = Some(err)
  self.drain()
  self.finish_failed(err)
}

///|
/// Ends a step after the error `err`: `NeedMoreOutput` while output from
/// before it is pending, then `err`, with the step's counts.
fn Decoder::finish_failed(
  self : Decoder,
  err : @codec.CodecError,
) -> Status raise @codec.CodecError {
  let status = self.finish_step(NeedMoreOutput)
  if self.pending > 0 {
    return status
  }
  raise err
}

///|
/// Drops the caller's buffers so a suspended decoder holds neither.
fn Decoder::release_step(self : Decoder) -> Unit {
  self.view = b""[:]
  self.in_pos = 0
  self.out = self.empty_out.mut_view()
  self.fixed_out = None
  self.out_pos = 0
}

// ---- input ----

///|
/// Gathers header bytes until `hdr` holds `n`.
fn Decoder::fill(self : Decoder, n : Int32) -> Unit raise Stop {
  let take = (n - self.hdr_len).min(self.view.length() - self.in_pos)
  if take > 0 {
    self.hdr.blit_from_bytesview(
      self.hdr_len,
      self.view[self.in_pos:self.in_pos + take],
    )
    self.hdr_len += take
    self.in_pos += take
  }
  if self.hdr_len < n {
    raise NeedInput
  }
}

///|
/// The little-endian value of `hdr[at:at + n]`, up to 8 bytes.
fn Decoder::hdr_le(self : Decoder, at : Int32, n : Int32) -> UInt64 {
  let mut v : UInt64 = 0
  for i = n - 1; i >= 0; i = i - 1 {
    v = (v << 8) | self.hdr[at + i].to_uint64()
  }
  v
}

// ---- window ----

///|
/// Makes `k` bytes writable, growing the window or handing out pending
/// output; false when the caller's buffer is full first.
fn Decoder::ensure_space(self : Decoder, k : Int32) -> Bool {
  let cap = self.ring.length()
  if cap == self.ring_max {
    if self.pending + k <= cap {
      return true
    }
    self.drain()
    return self.pending + k <= cap
  }
  if self.wpos + k <= cap {
    return true
  }
  let mut grown = cap.max(INITIAL_WINDOW)
  while grown < self.wpos + k && grown < self.ring_max {
    grown = grown * 2
  }
  let ring = FixedArray::make(grown.min(self.ring_max), b'\x00')
  FixedArray::unsafe_blit(ring, 0, self.ring, 0, self.wpos)
  self.ring = ring
  self.ensure_space(k)
}

///|
/// How many of `k` bytes can be written now: `k`, or fewer once the window
/// is full of pending output and the caller's buffer is full.
fn Decoder::room(self : Decoder, k : Int32) -> Int32 {
  if self.ensure_space(k) {
    k
  } else {
    self.ring.length() - self.pending
  }
}

///|
/// Accounts for `n` bytes just written at `wpos`.
fn Decoder::advance(self : Decoder, n : Int32) -> Unit {
  if self.has_checksum {
    self.xxh.update(self.ring, self.wpos, n)
  }
  self.wpos += n
  if self.wpos == self.ring_max {
    self.wpos = 0
  }
  self.pending += n
  self.filled = (self.filled + n).min(self.window)
  self.frame_out += n.to_uint64()
  self.block_out += n
}

///|
/// Writes `n` copies of `b`; `ensure_space(n)` has made room.
fn Decoder::put_run(self : Decoder, b : Byte, n : Int32) -> Unit {
  let mut remaining = n
  while remaining > 0 {
    let chunk = remaining.min(self.ring.length() - self.wpos)
    self.ring.fill(b, start=self.wpos, end=self.wpos + chunk)
    self.advance(chunk)
    remaining -= chunk
  }
}

///|
/// Copies `n` bytes of `src` from `at`; `ensure_space(n)` has made room.
fn Decoder::put_array(
  self : Decoder,
  src : FixedArray[Byte],
  at : Int32,
  n : Int32,
) -> Unit {
  let mut remaining = n
  let mut from = at
  while remaining > 0 {
    let chunk = remaining.min(self.ring.length() - self.wpos)
    FixedArray::unsafe_blit(self.ring, self.wpos, src, from, chunk)
    self.advance(chunk)
    from += chunk
    remaining -= chunk
  }
}

///|
/// Copies `n` input bytes from the view; `ensure_space(n)` has made room.
fn Decoder::copy_input(self : Decoder, n : Int32) -> Unit {
  let mut remaining = n
  while remaining > 0 {
    let chunk = remaining.min(self.ring.length() - self.wpos)
    self.ring.blit_from_bytesview(
      self.wpos,
      self.view[self.in_pos:self.in_pos + chunk],
    )
    self.in_pos += chunk
    self.advance(chunk)
    remaining -= chunk
  }
}

///|
/// Copies `n` bytes from `dist` back, `dist <= filled`; `ensure_space(n)`
/// has made room.
fn Decoder::copy_back(self : Decoder, dist : Int32, n : Int32) -> Unit {
  let ring = self.ring
  let cap = ring.length()
  let mut remaining = n
  while remaining > 0 {
    let mut src = self.wpos - dist
    if src < 0 {
      src += cap
    }
    let dst = self.wpos
    let chunk = remaining.min(cap - src).min(cap - dst)
    if dist >= chunk {
      FixedArray::unsafe_blit(ring, dst, ring, src, chunk)
    } else {
      // Overlapping: each byte may repeat one written in this copy.
      for i in 0..<chunk {
        ring[dst + i] = ring[src + i]
      }
    }
    self.advance(chunk)
    remaining -= chunk
  }
}

///|
/// Hands out as much pending output as the caller's buffer takes.
fn Decoder::drain(self : Decoder) -> Unit {
  let n = self.pending.min(self.out.length() - self.out_pos)
  guard n > 0 else { return }
  let cap = self.ring.length()
  let mut read = self.wpos - self.pending
  if read < 0 {
    read += cap
  }
  let first = n.min(cap - read)
  self.write_out(read, first)
  self.write_out(0, n - first)
  self.pending -= n
}

///|
fn Decoder::write_out(self : Decoder, start : Int32, n : Int32) -> Unit {
  match self.fixed_out {
    Some(out) => FixedArray::unsafe_blit(out, self.out_pos, self.ring, start, n)
    None =>
      for i in 0..<n {
        self.out[self.out_pos + i] = self.ring[start + i]
      }
  }
  self.out_pos += n
}

// ---- the state machine ----

///|
/// Runs units until the input or the output runs out or the stream ends.
fn Decoder::run(self : Decoder) -> Status raise @codec.CodecError {
  for ;; {
    let status = self.unit() catch {
      NeedInput => return NeedMoreInput
      Fail(kind, message) => raise CodecError(kind, message)
    }
    if status is Some(status) {
      return status
    }
  }
}

///|
/// One unit; `Some` stops the run.
fn Decoder::unit(self : Decoder) -> Status? raise Stop {
  match self.state {
    Magic => self.magic()
    SkippableSize => self.skippable_size()
    SkippableData => self.skippable_data()
    FrameHeader => self.frame_header()
    BlockHeader => return self.block_header()
    RawBlock => return self.raw_block()
    RleByte => self.rle_byte()
    RleRun => return self.rle_run()
    CompressedBlock => return self.compressed_block()
    Checksum => self.checksum()
    Done => {
      if self.until is EndOfInput && self.in_pos < self.view.length() {
        raise Fail(TrailingData, "data after the end of the stream")
      }
      return Some(Done)
    }
  }
  None
}

///|
/// Decodes through `Decoder::step`.
pub impl @codec_bytes.Decode for Decoder with fn step(self, input, output, end~) {
  Decoder::step(self, input, output, end~)
}

///|
/// Same as `Decoder::last_consumed`: input bytes the last step consumed.
pub impl @codec_bytes.Decode for Decoder with fn last_consumed(self) {
  Decoder::last_consumed(self)
}

///|
/// Same as `Decoder::last_produced`: output bytes the last step wrote.
pub impl @codec_bytes.Decode for Decoder with fn last_produced(self) {
  Decoder::last_produced(self)
}

///|
/// Same as `Decoder::reset`: back to the state of a new decoder with the same options.
pub impl @codec_bytes.Decode for Decoder with fn reset(self) {
  Decoder::reset(self)
}

///|
/// Same as `Decoder::memory_usage`: bytes allocated for the current stream.
pub impl @codec_bytes.Decode for Decoder with fn memory_usage(self) {
  Decoder::memory_usage(self)
}
