// The streaming decoder of LZ4 frames (and, inside, of LZ4 blocks).
//
// Suspension model: header fields gather in `hdr` (at most 19 bytes); a
// compressed block is decoded as its bytes arrive, a sequence at a time, and
// stops inside a sequence where the input or the room runs out. When the
// rest of a block is in the step's input, whole sequences decode in a tight
// loop (`fast_sequences`); anything it does not take on, the sequence-by-
// sequence path takes, which is the one place that refuses a broken block.
//
// Decoded bytes go to the window, a buffer that keeps the last 64 KiB (the
// most a match reaches back) and the output not handed out yet; it slides
// down when full. LZ4's blocks are at most 4 MiB, but nothing larger than
// the window is ever held: the window is all the decoder allocates for the
// stream. An error is kept in `failure` and raised once the output decoded
// before it is handed out, so that it comes after the same output whatever
// the split.

///|
priv enum State {
  Magic
  Descriptor
  FrameStart
  BlockHeader
  BlockStart
  Sequences
  Stored
  BlockChecksum
  ContentChecksum
  SkippableSize
  SkippableData
  LegacyBlockHeader
  Done
}

///|
/// Where the decoder is inside a sequence of a compressed block.
priv enum Seq {
  Token
  LitLen
  Literals
  Offset
  MatchLen
  Match
}

///|
priv suberror Stop {
  /// The unit needs bytes the input does not have yet.
  NeedInput
  /// The window is full of output the caller has not taken.
  NeedOutput
  /// The stream is refused.
  Fail(@codec.ErrorKind, String)
}

///|
/// The window's size once grown: the 64 KiB a match may reach back and
/// 192 KiB of room, so that it slides once for every 192 KiB of output.
const WINDOW : Int32 = 262144

///|
/// The window's first size; it doubles as output needs, up to `WINDOW`.
const INITIAL_WINDOW : Int32 = 4096

///|
/// A streaming LZ4 decoder: frames (with their checksums, dictionaries and
/// content sizes), skippable frames and legacy frames, one after another.
/// Feed it input in chunks of any size with `step` and collect output in
/// slices of any size. It holds a 256 KiB window at most and a few header
/// bytes, never a whole block, input or output.
pub struct Decoder {
  priv until : @codec_bytes.Until
  // The last 64 KiB of the caller's dictionary, kept by reference.
  priv dictionary : BytesView?
  // Block format only, for `decompress_block`: one block, the whole input,
  // that may decode to `block_max` bytes.
  priv raw : Bool
  // The input of the current step.
  priv mut view : BytesView
  priv mut in_pos : Int32
  // Header bytes gathered so far.
  priv hdr : FixedArray[Byte]
  priv mut hdr_len : Int32
  // The caller's output buffer for the current step.
  priv mut out : MutArrayView[Byte]
  priv mut out_pos : Int32
  priv empty_out : FixedArray[Byte]
  // The window: `pending` bytes before `wpos` are not handed out yet,
  // `hist` before it may be copied from (the current block's or frame's
  // output, and the dictionary), and `unhashed` before it are not yet in the
  // content checksum.
  priv mut win : FixedArray[Byte]
  priv mut wpos : Int32
  priv mut pending : Int32
  priv mut hist : Int32
  priv mut unhashed : Int32
  // Stream state.
  priv mut state : State
  // Whether a member (a frame, skippable or not) has ended.
  priv mut seen : Bool
  priv mut failure : @codec.CodecError?
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
  priv mut info : FrameInfo?
  // The current frame.
  priv mut legacy : Bool
  priv mut linked : Bool
  priv mut has_block_checksum : Bool
  priv mut has_content_checksum : Bool
  priv mut content_size : UInt64?
  priv mut block_max : Int32
  priv mut frame_out : UInt64
  priv xxh : Xxh32
  // The current block: what is left of its stored bytes, what it has
  // decoded, and the checksum of its stored bytes, which takes the step's
  // input from `bhash_from`.
  priv mut stored : Bool
  priv mut block_left : Int32
  priv mut block_out : Int32
  priv bxxh : Xxh32
  priv mut bhash_from : Int32
  // The current sequence.
  priv mut seq : Seq
  priv mut lit_left : Int32
  priv mut match_left : Int32
  priv mut match_nib : Int32
  priv mut offset : Int32
  priv mut offset_len : Int32
  // A skippable frame's bytes left.
  priv mut skip_left : Int64
}

///|
/// A decoder at the start of a stream.
///
/// `until` says where the stream ends. `EndOfInput`, the default, decodes
/// every frame up to the end of the input, skippable and legacy frames
/// among them, as `lz4 -d` does. `EndOfMember` stops right after the first
/// frame, a skippable frame included, and consumes nothing past it, so that
/// `input[last_consumed():]` is what follows; a legacy frame, which ends
/// only where the next frame or the input begins or ends, raises
/// `Unsupported` under it.
///
/// `dictionary` is the dictionary frames were written with (`lz4 -D`): its
/// last 64 KiB come as if just before a frame's output, before every block
/// of a frame of independent blocks. It serves every frame, whatever
/// dictionary id the frame names (`frame_info()` says which); without it, a
/// frame that names one raises `DictionaryRequired(Some(id))`. Legacy frames
/// take no dictionary. The decoder keeps the dictionary by reference, and
/// `memory_usage` does not count it.
pub fn Decoder::Decoder(
  until~ : @codec_bytes.Until = EndOfInput,
  dictionary? : BytesView,
) -> Decoder {
  Decoder::make(until, dictionary, false)
}

///|
fn Decoder::make(
  until : @codec_bytes.Until,
  dictionary : BytesView?,
  raw : Bool,
) -> Decoder {
  let dictionary = match dictionary {
    Some(d) if d.length() > 0 =>
      Some(d[(d.length() - MAX_DISTANCE).max(0):d.length()])
    _ => None
  }
  let empty_out = FixedArray::make(0, b'\x00')
  {
    until,
    dictionary,
    raw,
    view: b""[:],
    in_pos: 0,
    hdr: FixedArray::make(19, b'\x00'),
    hdr_len: 0,
    out: empty_out.mut_view(),
    out_pos: 0,
    empty_out,
    win: FixedArray::make(0, b'\x00'),
    wpos: 0,
    pending: 0,
    hist: 0,
    unhashed: 0,
    state: if raw {
      BlockStart
    } else {
      Magic
    },
    seen: false,
    failure: None,
    step_consumed: 0,
    step_produced: 0,
    info: None,
    legacy: false,
    linked: false,
    has_block_checksum: false,
    has_content_checksum: false,
    content_size: None,
    block_max: 0,
    frame_out: 0,
    xxh: Xxh32::new(),
    stored: false,
    block_left: 0,
    block_out: 0,
    bxxh: Xxh32::new(),
    bhash_from: 0,
    seq: Token,
    lit_left: 0,
    match_left: 0,
    match_nib: 0,
    offset: 0,
    offset_len: 0,
    skip_left: 0,
  }
}

///|
/// Back to the state of a new decoder with the same options; the window's
/// memory is kept.
pub fn Decoder::reset(self : Decoder) -> Unit {
  self.hdr_len = 0
  self.wpos = 0
  self.pending = 0
  self.hist = 0
  self.unhashed = 0
  self.state = if self.raw { BlockStart } else { Magic }
  self.seen = false
  self.failure = None
  self.step_consumed = 0
  self.step_produced = 0
  self.info = None
  self.legacy = false
  self.linked = false
  self.has_block_checksum = false
  self.has_content_checksum = false
  self.content_size = None
  self.block_max = 0
  self.frame_out = 0
  self.xxh.reset()
  self.stored = false
  self.block_left = 0
  self.block_out = 0
  self.bxxh.reset()
  self.seq = Token
  self.skip_left = 0
}

///|
/// Bytes the decoder holds: the window, at most 256 KiB
/// (`decoder_memory_bound()`), allocated as output needs it. The header
/// being read and the checksums' state (under 100 bytes) and the
/// dictionary, the caller's, are not counted.
pub fn Decoder::memory_usage(self : Decoder) -> Int32 {
  self.win.length()
}

///|
/// What the header of the frame being decoded, or of the last one, says;
/// None before the first frame's header. Skippable frames have none.
pub fn Decoder::frame_info(self : Decoder) -> FrameInfo? {
  self.info
}

///|
/// Whether the stream has ended and all its output has been handed out.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  self.state is Done && self.pending == 0 && self.failure is None
}

///|
/// Input bytes the latest `step` consumed: all of it on `NeedMoreInput`; up
/// to the error for a step that raised; for `TrailingData`, exactly up to
/// the end of the stream.
pub fn Decoder::last_consumed(self : Decoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote, a step that raised included.
pub fn Decoder::last_produced(self : Decoder) -> Int32 {
  self.step_produced
}

///|
/// Decodes from `input` into `output`. `end` says whether `input` holds the
/// last bytes: the stream may end there, after a whole frame or inside a
/// legacy frame's blocks, and anything cut short raises `Truncated`.
///
/// Answers `NeedMoreInput` once all of `input` is taken and everything it
/// decides is handed out, `NeedMoreOutput` while output waits for room, and
/// `Done` at the end of the stream. A block's bytes come out as they are
/// decoded, before the checksums that cover them are checked: they are
/// provisional, as the byte-stream contract has it (`decompress` returns
/// only checked output). A step that meets an error first hands out the
/// output before it (answering `NeedMoreOutput` while it does not fit),
/// then raises; after that the decoder raises it again, consuming and
/// writing nothing, until `reset`.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end~ : Bool,
) -> @codec_bytes.Status raise @codec.CodecError {
  self.step_consumed = 0
  self.step_produced = 0
  self.view = input
  self.in_pos = 0
  self.bhash_from = 0
  self.out = output
  self.out_pos = 0
  if self.failure is Some(err) {
    // Output from before the error that did not fit yet.
    self.drain()
    return self.finish_failed(err)
  }
  let status = self.run() catch { err => return self.fail(err) }
  let status : @codec_bytes.Status = match status {
    NeedMoreInput if end =>
      if self.state is Magic && self.hdr_len == 0 && self.seen {
        self.state = Done
        Done
      } else if self.state is LegacyBlockHeader && self.hdr_len == 0 {
        // A legacy frame ends where the input does.
        self.seen = true
        self.state = Done
        Done
      } else if self.state is Magic && self.hdr_len == 0 {
        return self.fail(
          @codec.CodecError(Truncated, "the input holds no frame"),
        )
      } else {
        return self.fail(
          @codec.CodecError(Truncated, "the input ends inside a frame"),
        )
      }
    status => status
  }
  self.drain()
  self.finish_step(if self.pending > 0 { NeedMoreOutput } else { status })
}

///|
fn Decoder::finish_step(
  self : Decoder,
  status : @codec_bytes.Status,
) -> @codec_bytes.Status {
  self.hash_block_input()
  self.step_consumed = self.in_pos
  self.step_produced = self.out_pos
  self.view = b""[:]
  self.in_pos = 0
  self.out = self.empty_out.mut_view()
  self.out_pos = 0
  status
}

///|
/// Records a terminal error, hands out the output before it, and raises it
/// once that is all out.
fn Decoder::fail(
  self : Decoder,
  err : @codec.CodecError,
) -> @codec_bytes.Status raise @codec.CodecError {
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
) -> @codec_bytes.Status raise @codec.CodecError {
  let pending = self.pending
  let status = self.finish_step(NeedMoreOutput)
  if pending > 0 {
    return status
  }
  raise err
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

///|
/// Adds the block's stored bytes taken in this step to its checksum.
fn Decoder::hash_block_input(self : Decoder) -> Unit {
  guard self.has_block_checksum &&
    (self.state is Sequences || self.state is Stored) &&
    self.in_pos > self.bhash_from else {
    return
  }
  self.bxxh.update_view(self.view[self.bhash_from:self.in_pos])
  self.bhash_from = self.in_pos
}

// ---- window ----

///|
/// Adds the output not yet in the content checksum to it.
fn Decoder::hash_content(self : Decoder) -> Unit {
  if self.unhashed > 0 {
    self.xxh.update(self.win, self.wpos - self.unhashed, self.unhashed)
    self.unhashed = 0
  }
}

///|
/// How many of `k` bytes (at least 1) can be written at `wpos` now: the
/// window grows, or hands out output and slides down, keeping the history
/// and the output not handed out. Raises `NeedOutput` when the window is
/// full of output the caller's buffer has no room for.
fn Decoder::room(self : Decoder, k : Int32) -> Int32 raise Stop {
  // Compared as differences: `k`, a match's length, may be near 2^31.
  if k <= self.win.length() - self.wpos {
    return k
  }
  self.make_room(k)
  let avail = self.win.length() - self.wpos
  if avail == 0 {
    raise NeedOutput
  }
  k.min(avail)
}

///|
/// Grows the window towards `wpos + k`, or, at its full size, hands out
/// output and slides it down.
fn Decoder::make_room(self : Decoder, k : Int32) -> Unit {
  let cap = self.win.length()
  if cap < WINDOW {
    let mut grown = cap.max(INITIAL_WINDOW)
    while grown - self.wpos < k && grown < WINDOW {
      grown = grown * 2
    }
    let win = FixedArray::make(grown.min(WINDOW), b'\x00')
    FixedArray::unsafe_blit(win, 0, self.win, 0, self.wpos)
    self.win = win
    return
  }
  self.drain()
  let keep = self.hist.min(MAX_DISTANCE).max(self.pending)
  if keep < self.wpos {
    self.hash_content()
    FixedArray::unsafe_blit(self.win, 0, self.win, self.wpos - keep, keep)
    self.wpos = keep
  }
}

///|
/// Accounts for `n` bytes just written at `wpos`.
fn Decoder::advance(self : Decoder, n : Int32) -> Unit {
  self.wpos += n
  self.pending += n
  self.hist = (self.hist + n).min(1 << 24)
  self.block_out += n
  self.frame_out += n.to_uint64()
  if self.has_content_checksum {
    self.unhashed += n
  }
}

///|
/// Starts history afresh with the dictionary, if there is one, as the
/// bytes before the next ones: at the start of a frame of linked blocks,
/// and of each independent block. The dictionary goes in after the output
/// is all handed out, so that it never sits among output.
fn Decoder::start_history(self : Decoder) -> Unit raise Stop {
  self.hist = 0
  guard self.dictionary is Some(dict) && !self.legacy else { return }
  self.drain()
  if self.pending > 0 {
    raise NeedOutput
  }
  self.hash_content()
  let n = dict.length()
  self.wpos = 0
  if self.win.length() < n {
    let _ = self.room(n)
  }
  self.win.blit_from_bytesview(0, dict)
  self.wpos = n
  self.hist = n
}

///|
/// Copies `n` bytes from `offset` back to `wpos`; `room(n)` has made room.
fn Decoder::copy_back(self : Decoder, n : Int32) -> Unit {
  let from = self.wpos - self.offset
  if self.offset >= n {
    FixedArray::unsafe_blit(self.win, self.wpos, self.win, from, n)
  } else {
    // Overlapping: the copy repeats bytes it writes.
    @blit.forward(self.win, self.wpos, from, n)
  }
  self.advance(n)
}

///|
/// Hands out as much pending output as the caller's buffer takes.
fn Decoder::drain(self : Decoder) -> Unit {
  let n = self.pending.min(self.out.length() - self.out_pos)
  guard n > 0 else { return }
  @blit.into_view(self.out, self.out_pos, self.win, self.wpos - self.pending, n)
  self.out_pos += n
  self.pending -= n
}

// ---- the state machine ----

///|
/// Runs units until the input or the output runs out or the stream ends.
fn Decoder::run(self : Decoder) -> @codec_bytes.Status raise @codec.CodecError {
  for ;; {
    let done = self.unit() catch {
      NeedInput => return NeedMoreInput
      NeedOutput => return NeedMoreOutput
      Fail(kind, message) => raise @codec.CodecError(kind, message)
    }
    if done {
      return Done
    }
  }
}

///|
/// One unit; true at the end of the stream.
fn Decoder::unit(self : Decoder) -> Bool raise Stop {
  match self.state {
    Magic => self.magic()
    Descriptor => self.descriptor()
    FrameStart => {
      if self.linked {
        self.start_history()
      }
      self.state = BlockHeader
    }
    BlockHeader => self.block_header()
    BlockStart => self.block_start()
    Sequences => self.sequences()
    Stored => self.stored_block()
    BlockChecksum => self.block_checksum()
    ContentChecksum => self.content_checksum()
    SkippableSize => {
      self.fill(8)
      self.skip_left = self.hdr_le(4, 4).reinterpret_as_int64()
      self.hdr_len = 0
      self.state = SkippableData
    }
    SkippableData => {
      let take = self.skip_left.min(
        (self.view.length() - self.in_pos).to_int64(),
      )
      self.in_pos += take.to_int()
      self.skip_left -= take
      if self.skip_left > 0 {
        raise NeedInput
      }
      self.end_member()
    }
    LegacyBlockHeader => self.legacy_block_header()
    Done => {
      if self.until is EndOfInput && self.in_pos < self.view.length() {
        raise Fail(TrailingData, "data after the last frame")
      }
      return true
    }
  }
  false
}

///|
/// The magic number that starts every frame.
fn Decoder::magic(self : Decoder) -> Unit raise Stop {
  // The bytes are refused as soon as they begin no magic number, so that
  // a byte after the last frame is trailing data even when it is alone.
  let take = (4 - self.hdr_len).min(self.view.length() - self.in_pos)
  if take > 0 {
    self.hdr.blit_from_bytesview(
      self.hdr_len,
      self.view[self.in_pos:self.in_pos + take],
    )
    self.hdr_len += take
    self.in_pos += take
  }
  if !magic_prefix(self.hdr, self.hdr_len) {
    if !self.seen {
      raise Fail(Corrupt, "not an LZ4 stream")
    }
    // The stream ends where these bytes begin, if in this step's input.
    self.in_pos = (self.in_pos - self.hdr_len).max(0)
    raise Fail(TrailingData, "data after the last frame")
  }
  if self.hdr_len < 4 {
    raise NeedInput
  }
  let magic = self.hdr_le(0, 4).to_uint()
  if magic == FRAME_MAGIC {
    self.hdr_len = 0
    self.state = Descriptor
  } else if (magic & 0xFFFFFFF0) == 0x184D2A50 {
    self.state = SkippableSize
  } else if magic == LEGACY_MAGIC {
    if self.until is EndOfMember {
      raise Fail(
        Unsupported,
        "a legacy frame, whose end shows only after it, under EndOfMember",
      )
    }
    self.hdr_len = 0
    self.legacy = true
    self.linked = false
    self.has_block_checksum = false
    self.has_content_checksum = false
    self.content_size = None
    self.block_max = LEGACY_BLOCK
    self.frame_out = 0
    self.info = Some({
      block_size: None,
      linked: false,
      block_checksum: false,
      content_checksum: false,
      content_size: None,
      dictionary_id: None,
      legacy: true,
    })
    self.state = LegacyBlockHeader
  }
}

///|
/// Whether the first `n` bytes of `hdr` begin a magic number, little-endian:
/// a frame's (04 22 4D 18), a legacy frame's (02 21 4C 18) or a skippable
/// frame's (5x 2A 4D 18).
fn magic_prefix(hdr : FixedArray[Byte], n : Int32) -> Bool {
  let frame : FixedArray[Byte] = [b'\x04', b'\x22', b'\x4D', b'\x18']
  let legacy : FixedArray[Byte] = [b'\x02', b'\x21', b'\x4C', b'\x18']
  let skippable : FixedArray[Byte] = [b'\x50', b'\x2A', b'\x4D', b'\x18']
  let mut is_frame = true
  let mut is_legacy = true
  let mut is_skippable = true
  for i in 0..<n {
    let b = hdr[i]
    is_frame = is_frame && b == frame[i]
    is_legacy = is_legacy && b == legacy[i]
    // The first byte's low four bits are the skippable frame's variant.
    let masked = if i == 0 { b & b'\xF0' } else { b }
    is_skippable = is_skippable && masked == skippable[i]
  }
  is_frame || is_legacy || is_skippable
}

///|
/// The frame descriptor: FLG, BD, the content size and dictionary id when
/// present, and the header checksum.
fn Decoder::descriptor(self : Decoder) -> Unit raise Stop {
  self.fill(2)
  let flg = self.hdr[0].to_int()
  let bd = self.hdr[1].to_int()
  if flg >> 6 != 1 {
    raise Fail(Unsupported, "a frame of version \{flg >> 6}, not 1")
  }
  if (flg & 0x02) != 0 || (bd & 0x8F) != 0 {
    raise Fail(Unsupported, "a frame whose header sets a reserved bit")
  }
  let block_size = match (bd >> 4) & 7 {
    4 => Max64KiB
    5 => Max256KiB
    6 => Max1MiB
    7 => Max4MiB
    code => raise Fail(Unsupported, "a block size code of \{code}")
  }
  let has_size = (flg & 0x08) != 0
  let has_dict = (flg & 0x01) != 0
  let len = 3 + (if has_size { 8 } else { 0 }) + (if has_dict { 4 } else { 0 })
  self.fill(len)
  let hc = (xxh32(self.hdr.unsafe_reinterpret_as_bytes()[0:len - 1]) >> 8) &
    0xFF
  if hc.reinterpret_as_int() != self.hdr[len - 1].to_int() {
    raise Fail(ChecksumMismatch, "the frame header's checksum does not match")
  }
  let content_size = if has_size { Some(self.hdr_le(2, 8)) } else { None }
  let dictionary_id = if has_dict {
    Some(self.hdr_le(if has_size { 10 } else { 2 }, 4).to_uint())
  } else {
    None
  }
  if dictionary_id is Some(id) && self.dictionary is None {
    raise Fail(DictionaryRequired(Some(id)), "the frame needs dictionary \{id}")
  }
  self.hdr_len = 0
  self.legacy = false
  self.linked = (flg & 0x20) == 0
  self.has_block_checksum = (flg & 0x10) != 0
  self.has_content_checksum = (flg & 0x04) != 0
  self.content_size = content_size
  self.block_max = block_size.bytes()
  self.frame_out = 0
  self.xxh.reset()
  self.info = Some({
    block_size: Some(block_size),
    linked: self.linked,
    block_checksum: self.has_block_checksum,
    content_checksum: self.has_content_checksum,
    content_size,
    dictionary_id,
    legacy: false,
  })
  self.state = FrameStart
}

///|
/// A block's size, or the end mark.
fn Decoder::block_header(self : Decoder) -> Unit raise Stop {
  self.fill(4)
  let v = self.hdr_le(0, 4).to_int()
  self.hdr_len = 0
  if v == 0 {
    if self.has_content_checksum {
      self.state = ContentChecksum
    } else {
      self.end_frame()
    }
    return
  }
  let size = v & 0x7FFFFFFF
  if size > self.block_max {
    raise Fail(
      Corrupt,
      "a block of \{size} bytes, over the frame's \{self.block_max}",
    )
  }
  self.stored = v < 0
  self.begin_block(size)
}

///|
/// Starts a block of `size` stored bytes.
fn Decoder::begin_block(self : Decoder, size : Int32) -> Unit {
  self.block_left = size
  self.block_out = 0
  if self.has_block_checksum {
    self.bxxh.reset()
    self.bhash_from = self.in_pos
  }
  self.state = BlockStart
}

///|
/// The history a block starts with, then its bytes.
fn Decoder::block_start(self : Decoder) -> Unit raise Stop {
  if self.raw {
    self.block_left = self.view.length() - self.in_pos
    self.block_out = 0
    self.start_history()
    self.seq = Token
    self.state = Sequences
    return
  }
  if self.stored {
    if self.content_size is Some(cs) &&
      self.frame_out + self.block_left.to_uint64() > cs {
      raise Fail(
        ChecksumMismatch,
        "the frame holds more than its declared content size",
      )
    }
    self.state = Stored
    return
  }
  if !self.linked {
    self.start_history()
  }
  self.seq = Token
  self.state = Sequences
}

///|
/// An uncompressed block's bytes, as they arrive.
fn Decoder::stored_block(self : Decoder) -> Unit raise Stop {
  while self.block_left > 0 {
    let n = self.block_left.min(self.view.length() - self.in_pos)
    if n == 0 {
      raise NeedInput
    }
    let n = self.room(n)
    self.win.blit_from_bytesview(
      self.wpos,
      self.view[self.in_pos:self.in_pos + n],
    )
    self.in_pos += n
    self.block_left -= n
    self.advance(n)
  }
  self.end_block()
}

///|
/// After a block's last byte: its checksum, or the next block.
fn Decoder::end_block(self : Decoder) -> Unit {
  self.hash_block_input()
  self.state = if self.raw {
    Done
  } else if self.has_block_checksum {
    BlockChecksum
  } else if self.legacy {
    LegacyBlockHeader
  } else {
    BlockHeader
  }
}

///|
fn Decoder::block_checksum(self : Decoder) -> Unit raise Stop {
  self.fill(4)
  let stored = self.hdr_le(0, 4).to_uint()
  self.hdr_len = 0
  if stored != self.bxxh.digest() {
    raise Fail(
      ChecksumMismatch,
      "a block's checksum does not match its stored bytes",
    )
  }
  self.state = BlockHeader
}

///|
fn Decoder::content_checksum(self : Decoder) -> Unit raise Stop {
  self.fill(4)
  let stored = self.hdr_le(0, 4).to_uint()
  self.hdr_len = 0
  self.hash_content()
  if stored != self.xxh.digest() {
    raise Fail(ChecksumMismatch, "the frame's content checksum does not match")
  }
  self.end_frame()
}

///|
/// After the end mark (and the content checksum): the declared content size
/// is checked, and the next member follows.
fn Decoder::end_frame(self : Decoder) -> Unit raise Stop {
  if self.content_size is Some(cs) && self.frame_out != cs {
    raise Fail(
      ChecksumMismatch,
      "the frame holds less than its declared content size",
    )
  }
  self.end_member()
}

///|
fn Decoder::end_member(self : Decoder) -> Unit {
  self.seen = true
  self.hdr_len = 0
  self.state = if self.until is EndOfMember { Done } else { Magic }
}

///|
/// A legacy block's compressed size, or the magic number of the next frame,
/// which ends the legacy frame.
fn Decoder::legacy_block_header(self : Decoder) -> Unit raise Stop {
  // As in `magic`: bytes that can begin neither a block size nor a magic
  // number end the stream as soon as they are seen.
  let take = (4 - self.hdr_len).min(self.view.length() - self.in_pos)
  if take > 0 {
    self.hdr.blit_from_bytesview(
      self.hdr_len,
      self.view[self.in_pos:self.in_pos + take],
    )
    self.hdr_len += take
    self.in_pos += take
  }
  if self.hdr_len < 4 {
    // The bytes so far are the size's low bytes: the smallest size they
    // begin is theirs, with zeros above.
    if self.hdr_len > 0 &&
      self.hdr_le(0, self.hdr_len).to_int() > LEGACY_BOUND &&
      !magic_prefix(self.hdr, self.hdr_len) {
      self.seen = true
      self.in_pos = (self.in_pos - self.hdr_len).max(0)
      raise Fail(TrailingData, "data after the last frame")
    }
    raise NeedInput
  }
  let v = self.hdr_le(0, 4).to_uint()
  if v == FRAME_MAGIC || v == LEGACY_MAGIC || (v & 0xFFFFFFF0) == 0x184D2A50 {
    // The four bytes are kept: `magic` reads them again.
    self.seen = true
    self.state = Magic
    return
  }
  if v.reinterpret_as_int() > LEGACY_BOUND || v.reinterpret_as_int() < 0 {
    self.seen = true
    self.in_pos = (self.in_pos - self.hdr_len).max(0)
    raise Fail(TrailingData, "data after the last frame")
  }
  self.hdr_len = 0
  self.stored = false
  self.begin_block(v.reinterpret_as_int())
}

// ---- compressed blocks ----

///|
/// Refuses `n` more bytes of output that would pass the block's maximum
/// or the frame's declared content size.
fn Decoder::check_length(self : Decoder, n : Int32) -> Unit raise Stop {
  if n > self.block_max - self.block_out {
    self.too_long()
  }
  if self.content_size is Some(cs) && self.frame_out + n.to_uint64() > cs {
    raise Fail(
      ChecksumMismatch,
      "the frame holds more than its declared content size",
    )
  }
}

///|
/// Refuses output past the block's maximum: `max_output` for a block on
/// its own, the frame's block size otherwise.
fn Decoder::too_long(self : Decoder) -> Unit raise Stop {
  if self.raw {
    raise Fail(
      LimitExceeded({
        resource: Output,
        needed: None,
        limit: self.block_max.to_uint64(),
      }),
      "the block decodes to more than \{self.block_max} bytes",
    )
  }
  raise Fail(Corrupt, "a block that decodes to more than its maximum size")
}

///|
/// The next byte of the block's stored bytes, for a length or an offset.
fn Decoder::block_byte(self : Decoder) -> Int32 raise Stop {
  if self.block_left == 0 {
    raise Fail(Corrupt, "the block ends inside a sequence")
  }
  if self.in_pos == self.view.length() {
    raise NeedInput
  }
  let b = self.view[self.in_pos].to_int()
  self.in_pos += 1
  self.block_left -= 1
  b
}

///|
/// Decodes the block's sequences as far as the input and the room go.
fn Decoder::sequences(self : Decoder) -> Unit raise Stop {
  for ;; {
    match self.seq {
      Token => {
        self.fast_sequences()
        if self.seq is Literals {
          // `fast_sequences` decoded the last one.
          continue
        }
        if self.block_left == 0 {
          raise Fail(Corrupt, "the block does not end with literals")
        }
        let token = self.block_byte()
        self.lit_left = token >> 4
        self.match_nib = token & 15
        if self.lit_left == 15 {
          self.seq = LitLen
        } else {
          self.check_length(self.lit_left)
          self.seq = Literals
        }
      }
      LitLen => {
        let b = self.block_byte()
        // Compared before it is added, so that it cannot overflow.
        if b > self.block_max - self.lit_left {
          self.too_long()
        }
        self.lit_left += b
        if b != 255 {
          self.check_length(self.lit_left)
          self.seq = Literals
        }
      }
      Literals => {
        if self.lit_left > self.block_left {
          raise Fail(Corrupt, "literals past the end of the block")
        }
        while self.lit_left > 0 {
          let n = self.lit_left.min(self.view.length() - self.in_pos)
          if n == 0 {
            raise NeedInput
          }
          let n = self.room(n)
          self.win.blit_from_bytesview(
            self.wpos,
            self.view[self.in_pos:self.in_pos + n],
          )
          self.in_pos += n
          self.block_left -= n
          self.lit_left -= n
          self.advance(n)
        }
        if self.block_left == 0 {
          self.end_block()
          return
        }
        self.offset = 0
        self.offset_len = 0
        self.seq = Offset
      }
      Offset => {
        while self.offset_len < 2 {
          self.offset = self.offset |
            (self.block_byte() << (8 * self.offset_len))
          self.offset_len += 1
        }
        if self.offset == 0 {
          raise Fail(Corrupt, "a match with an offset of 0")
        }
        if self.offset > self.hist {
          raise Fail(Corrupt, "a match from before the start of the data")
        }
        self.match_left = self.match_nib + 4
        if self.match_nib == 15 {
          self.seq = MatchLen
        } else {
          self.check_length(self.match_left)
          self.seq = Match
        }
      }
      MatchLen => {
        let b = self.block_byte()
        if b > self.block_max - self.match_left {
          self.too_long()
        }
        self.match_left += b
        if b != 255 {
          self.check_length(self.match_left)
          self.seq = Match
        }
      }
      Match => {
        while self.match_left > 0 {
          let n = self.room(self.match_left)
          self.copy_back(n)
          self.match_left -= n
        }
        self.seq = Token
      }
    }
  }
}

///|
/// Decodes whole sequences while the rest of the block is in the step's
/// input and each sequence fits the window, and stops at the start of the
/// first one it does not take on, which `sequences` then decodes or
/// refuses. After the block's last sequence, it leaves `seq` at `Literals`
/// with none left.
fn Decoder::fast_sequences(self : Decoder) -> Unit {
  let view = self.view
  guard self.block_left <= view.length() - self.in_pos else { return }
  let end = self.in_pos + self.block_left
  // The window's position, the history and what the block and the frame
  // may still take are kept in locals, and committed when the loop stops or
  // the window must slide.
  let mut ip = self.in_pos
  let mut w = self.wpos
  let mut win = self.win
  let mut hist = self.hist
  let mut budget = self.block_max - self.block_out
  if self.content_size is Some(cs) {
    let left = cs - self.frame_out
    if left < budget.to_uint64() {
      budget = left.to_int()
    }
  }
  while ip < end {
    let token = view.unsafe_get(ip).to_int()
    let mut p = ip + 1
    let mut lit = token >> 4
    if lit == 15 {
      for ;; {
        guard p < end else { return self.commit_fast(w, ip, end) }
        let b = view.unsafe_get(p).to_int()
        p += 1
        // Compared before it is added, so that it cannot overflow.
        guard b <= end - p - lit else { return self.commit_fast(w, ip, end) }
        lit += b
        if b != 255 {
          break
        }
      }
    }
    guard lit <= end - p else { return self.commit_fast(w, ip, end) }
    let lit_at = p
    p += lit
    let last = p == end
    let mut offset = 0
    let mut len = 0
    if !last {
      guard end - p >= 2 else { return self.commit_fast(w, ip, end) }
      offset = view.unsafe_get(p).to_int() |
        (view.unsafe_get(p + 1).to_int() << 8)
      p += 2
      len = (token & 15) + 4
      if (token & 15) == 15 {
        for ;; {
          guard p < end else { return self.commit_fast(w, ip, end) }
          let b = view.unsafe_get(p).to_int()
          p += 1
          guard b <= budget - len else { return self.commit_fast(w, ip, end) }
          len += b
          if b != 255 {
            break
          }
        }
      }
      guard offset != 0 && offset <= hist + lit else {
        return self.commit_fast(w, ip, end)
      }
    }
    // Compared before they are added, so that the sum cannot overflow.
    guard len <= budget - lit else { return self.commit_fast(w, ip, end) }
    let need = lit + len
    if need > win.length() - w {
      self.commit_fast(w, ip, end)
      self.make_room(need)
      w = self.wpos
      win = self.win
      hist = self.hist
      guard need <= win.length() - w else { return }
    }
    // Short copies byte by byte: a block copy costs more than they do.
    if lit > 16 {
      win.blit_from_bytesview(w, view[lit_at:lit_at + lit])
    } else {
      for i in 0..<lit {
        win.unsafe_set(w + i, view.unsafe_get(lit_at + i))
      }
    }
    w += lit
    if len > 0 {
      let from = w - offset
      if offset < len {
        // Overlapping: the copy repeats bytes it writes.
        @blit.forward(win, w, from, len)
      } else if len > 16 {
        FixedArray::unsafe_blit(win, w, win, from, len)
      } else {
        for i in 0..<len {
          win.unsafe_set(w + i, win.unsafe_get(from + i))
        }
      }
      w += len
    }
    hist += need
    budget -= need
    ip = p
    if last {
      self.commit_fast(w, ip, end)
      self.lit_left = 0
      self.seq = Literals
      return
    }
  }
  self.commit_fast(w, ip, end)
}

///|
/// Commits what `fast_sequences` decoded: the window up to `w`, the input
/// up to `ip` of the block that ends at `end`.
fn Decoder::commit_fast(
  self : Decoder,
  w : Int32,
  ip : Int32,
  end : Int32,
) -> Unit {
  self.advance(w - self.wpos)
  self.in_pos = ip
  self.block_left = end - ip
}
