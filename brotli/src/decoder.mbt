// The streaming decoder.
//
// Suspension model (as in moonbit-community/flate's `Inflater`): the stream
// is decoded in small atomic units (a header field, one code length, one
// command, one literal). A unit reads all its bits before it changes any
// state; when the input runs out mid-unit it raises `NeedInput`, the bit
// reader rewinds to the unit's start, and the at most few bytes of the
// unfinished unit are kept in `stash` so the caller may drop the whole
// chunk. Decoded bytes go to the sliding window and are copied out to the
// caller's buffer, so output can be handed out in slices of any size.

///|
priv enum State {
  StreamHeader
  MetaHeader
  Metadata
  Uncompressed
  NumBlockTypes
  BlockTypeCode
  BlockCountCode
  FirstBlockCount
  DistanceParams
  ContextModes
  NumTrees
  ContextMapHeader
  ContextMapCode
  ContextMapEntries
  ContextMapImtf
  TreeCodes
  CommandStart
  Literals
  Distance
  Copy
  MetaDone
  Done
}

///|
/// The block length of a category with a single block type: longer than any
/// meta-block, so it never runs out.
const ENDLESS_BLOCK : Int32 = 0x40000000

///|
/// The first window allocation; it doubles as output grows, up to the
/// declared window.
const INITIAL_WINDOW : Int32 = 1024

///|
/// A streaming Brotli decoder (RFC 7932). Feed it input in chunks of any
/// size with `step` and collect output in slices of any size; it keeps the
/// sliding window (at most 16 MiB, and no more than the output so far) plus
/// fixed-size tables, never the whole input or output.
pub struct Decoder {
  priv max_window_bits : Int32
  // Bit reader. `acc` holds `nbits` unread bits, least significant first;
  // they come from `stash` and then from `view`.
  priv mut acc : Int32
  priv mut nbits : Int32
  priv mut stash : Array[Byte]
  priv mut stash_pos : Int32
  priv mut view : BytesView
  priv mut in_pos : Int32
  // The bit reader at the start of the current unit.
  priv mut save_acc : Int32
  priv mut save_nbits : Int32
  priv mut save_stash_pos : Int32
  priv mut save_in_pos : Int32
  // The caller's output buffer for the current step.
  priv mut out : MutArrayView[Byte]
  priv mut fixed_out : FixedArray[Byte]?
  priv mut out_pos : Int32
  priv empty_out : FixedArray[Byte]
  // The sliding window: a ring of `ring_max = 1 << WBITS` bytes, allocated
  // as output grows. `pending` bytes before `wpos` are not handed out yet;
  // `filled` is how far back a distance may reach, min(output, window).
  priv mut ring : FixedArray[Byte]
  priv mut ring_max : Int32
  priv mut window : Int32
  priv mut wpos : Int32
  priv mut pending : Int32
  priv mut filled : Int32
  // Stream state.
  priv mut state : State
  priv mut is_last : Bool
  priv mut meta_remaining : Int32
  priv mut failure : BrotliError?
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
  // Compressed meta-block header. `cat` is the category being read
  // (0 literals, 1 insert-and-copy, 2 distances); `index` counts entries.
  priv mut cat : Int32
  priv mut index : Int32
  priv num_types : FixedArray[Int32]
  priv block_type : FixedArray[Int32]
  priv prev_block_type : FixedArray[Int32]
  priv block_len : FixedArray[Int32]
  priv type_codes : FixedArray[Group]
  priv count_codes : FixedArray[Group]
  priv mut npostfix : Int32
  priv mut ndirect : Int32
  priv context_modes : FixedArray[Int32]
  priv mut lit_trees_count : Int32
  priv mut dist_trees_count : Int32
  priv lit_context_map : FixedArray[Byte]
  priv dist_context_map : FixedArray[Byte]
  priv mut map_size : Int32
  priv mut map_rle_max : Int32
  priv map_code : Group
  priv lit_trees : Group
  priv cmd_trees : Group
  priv dist_trees : Group
  priv code : CodeReader
  priv builder : Builder
  // Commands.
  priv mut lit_mode : Int32
  priv mut lit_map_offset : Int32
  priv mut dist_map_offset : Int32
  priv mut insert_remaining : Int32
  priv mut copy_len : Int32
  priv mut copy_remaining : Int32
  priv mut copy_dist : Int32
  priv mut implicit_distance : Bool
  priv dist_ring : FixedArray[Int32]
  priv mut dist_ring_index : Int32
  priv word : FixedArray[Byte]
}

///|
/// A decoder at the start of a stream. It refuses, with `WindowTooLarge`,
/// a stream whose window exceeds `1 << max_window_bits` bytes (the window
/// memory it would need); the default 24 accepts every RFC 7932 stream.
/// Values are clamped to 10..24.
pub fn Decoder::Decoder(max_window_bits~ : Int32 = 24) -> Decoder {
  let empty_out = FixedArray::make(0, b'\x00')
  {
    max_window_bits: max_window_bits.clamp(min=10, max=24),
    acc: 0,
    nbits: 0,
    stash: [],
    stash_pos: 0,
    view: b""[:],
    in_pos: 0,
    save_acc: 0,
    save_nbits: 0,
    save_stash_pos: 0,
    save_in_pos: 0,
    out: empty_out.mut_view(),
    fixed_out: None,
    out_pos: 0,
    empty_out,
    ring: FixedArray::make(0, b'\x00'),
    ring_max: 0,
    window: 0,
    wpos: 0,
    pending: 0,
    filled: 0,
    state: StreamHeader,
    is_last: false,
    meta_remaining: 0,
    failure: None,
    step_consumed: 0,
    step_produced: 0,
    cat: 0,
    index: 0,
    num_types: FixedArray::make(3, 1),
    block_type: FixedArray::make(3, 0),
    prev_block_type: FixedArray::make(3, 1),
    block_len: FixedArray::make(3, ENDLESS_BLOCK),
    type_codes: FixedArray::makei(3, _ => Group::new(1)),
    count_codes: FixedArray::makei(3, _ => Group::new(1)),
    npostfix: 0,
    ndirect: 0,
    context_modes: FixedArray::make(256, 0),
    lit_trees_count: 1,
    dist_trees_count: 1,
    lit_context_map: FixedArray::make(64 * 256, b'\x00'),
    dist_context_map: FixedArray::make(4 * 256, b'\x00'),
    map_size: 0,
    map_rle_max: 0,
    map_code: Group::new(1),
    lit_trees: Group::new(256),
    cmd_trees: Group::new(256),
    dist_trees: Group::new(256),
    code: CodeReader::new(),
    builder: Builder::new(),
    lit_mode: 0,
    lit_map_offset: 0,
    dist_map_offset: 0,
    insert_remaining: 0,
    copy_len: 0,
    copy_remaining: 0,
    copy_dist: 0,
    implicit_distance: false,
    dist_ring: [16, 15, 11, 4],
    dist_ring_index: 0,
    word: FixedArray::make(MAX_TRANSFORMED_WORD, b'\x00'),
  }
}

///|
/// Starts a new stream, keeping the tables' memory. The window is released.
pub fn Decoder::reset(self : Decoder) -> Unit {
  self.acc = 0
  self.nbits = 0
  self.stash = []
  self.stash_pos = 0
  self.release_step()
  self.ring = FixedArray::make(0, b'\x00')
  self.ring_max = 0
  self.window = 0
  self.wpos = 0
  self.pending = 0
  self.filled = 0
  self.state = StreamHeader
  self.is_last = false
  self.meta_remaining = 0
  self.failure = None
  self.step_consumed = 0
  self.step_produced = 0
  self.dist_ring[0] = 16
  self.dist_ring[1] = 15
  self.dist_ring[2] = 11
  self.dist_ring[3] = 4
  self.dist_ring_index = 0
}

///|
/// Whether the stream has ended and all its output has been handed out.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  self.state is Done && self.pending == 0
}

///|
/// Input bytes the latest `step` accepted: all of them on `NeedMoreInput`.
/// Zero after a step that raised.
pub fn Decoder::last_consumed(self : Decoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote. Zero after a step that raised.
pub fn Decoder::last_produced(self : Decoder) -> Int32 {
  self.step_produced
}

///|
/// Decodes from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used. Pass `end=true` once
/// `input` holds the last bytes of the stream, so that a stream cut short
/// raises `Truncated` instead of asking for more. Bytes after the end of the
/// stream raise `TrailingData`. After an error the decoder raises it again
/// until `reset`.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end~ : Bool = false,
) -> Status raise BrotliError {
  self.step_with(input, output, None, end~)
}

///|
/// `step` into a whole `FixedArray`, with bulk copies.
pub fn Decoder::step_into(
  self : Decoder,
  input : BytesView,
  output : FixedArray[Byte],
  end~ : Bool = false,
) -> Status raise BrotliError {
  self.step_with(input, output.mut_view(), Some(output), end~)
}

///|
fn Decoder::step_with(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  end~ : Bool,
) -> Status raise BrotliError {
  self.step_consumed = 0
  self.step_produced = 0
  if self.failure is Some(err) {
    raise err
  }
  self.view = input
  self.in_pos = 0
  self.out = output
  self.fixed_out = fixed_output
  self.out_pos = 0
  let status = self.run() catch { err => self.fail(err) }
  match status {
    NeedMoreInput => {
      // Keep the unfinished unit's bytes; the caller may drop the chunk.
      let kept = self.stash[self.stash_pos:].to_owned()
      kept.push_iter(self.view[self.in_pos:].iter())
      self.stash = kept
      self.stash_pos = 0
      self.in_pos = self.view.length()
      if end {
        self.fail(BrotliError(Truncated, "the stream ends early"))
      }
      self.drain()
      self.finish_step(if self.pending > 0 { NeedMoreOutput } else { status })
    }
    Done => {
      if self.nbits > 0 ||
        self.stash_pos < self.stash.length() ||
        self.in_pos < self.view.length() {
        self.fail(BrotliError(TrailingData, "data after the end of the stream"))
      }
      self.drain()
      self.finish_step(if self.pending > 0 { NeedMoreOutput } else { Done })
    }
    NeedMoreOutput => {
      self.drain()
      self.finish_step(status)
    }
  }
}

///|
fn Decoder::finish_step(self : Decoder, status : Status) -> Status {
  if self.stash_pos > 0 {
    self.stash = self.stash[self.stash_pos:].to_owned()
    self.stash_pos = 0
  }
  self.step_consumed = self.in_pos
  self.step_produced = self.out_pos
  self.release_step()
  status
}

///|
/// Records a terminal error and raises it.
fn[T] Decoder::fail(self : Decoder, err : BrotliError) -> T raise BrotliError {
  self.failure = Some(err)
  self.stash = []
  self.stash_pos = 0
  self.release_step()
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

// ---- bit reader ----

///|
fn Decoder::checkpoint(self : Decoder) -> Unit {
  self.save_acc = self.acc
  self.save_nbits = self.nbits
  self.save_stash_pos = self.stash_pos
  self.save_in_pos = self.in_pos
}

///|
fn Decoder::rewind(self : Decoder) -> Unit {
  self.acc = self.save_acc
  self.nbits = self.save_nbits
  self.stash_pos = self.save_stash_pos
  self.in_pos = self.save_in_pos
}

///|
/// Moves the next input byte into `acc`; false when there is none.
fn Decoder::load_byte(self : Decoder) -> Bool {
  let byte = if self.stash_pos < self.stash.length() {
    let b = self.stash[self.stash_pos]
    self.stash_pos += 1
    b
  } else if self.in_pos < self.view.length() {
    let b = self.view[self.in_pos]
    self.in_pos += 1
    b
  } else {
    return false
  }
  self.acc = self.acc | (byte.to_int() << self.nbits)
  self.nbits += 8
  true
}

///|
/// Loads whole bytes until at least 24 bits are buffered or the input runs
/// out. `acc` stays below 2^31.
fn Decoder::refill(self : Decoder) -> Unit {
  while self.nbits <= 23 && self.load_byte() {

  }
}

///|
/// The next `n` (at most 24) bits.
fn Decoder::read_bits(self : Decoder, n : Int32) -> Int32 raise Stop {
  if self.nbits < n {
    self.refill()
    if self.nbits < n {
      raise NeedInput
    }
  }
  let v = self.acc & ((1 << n) - 1)
  self.acc = self.acc >> n
  self.nbits -= n
  v
}

///|
/// The next symbol of tree `tree` of `group`.
fn Decoder::read_symbol(
  self : Decoder,
  group : Group,
  tree : Int32,
) -> Int32 raise Stop {
  if self.nbits < MAX_CODE_LENGTH {
    self.refill()
  }
  let pool = group.pool
  let base = group.offsets[tree]
  let mut entry = pool[base + (self.acc & (ROOT_SIZE - 1))].to_int()
  let mut bits = entry & 15
  if bits > ROOT_BITS {
    let sub = (self.acc >> ROOT_BITS) & ((1 << (bits - ROOT_BITS)) - 1)
    entry = pool[base + (entry >> 4) + sub].to_int()
    bits = entry & 15
  }
  // Bits past the input read as zero; the symbol is right if its code fits
  // in the bits that are really there.
  if bits > self.nbits {
    raise NeedInput
  }
  self.acc = self.acc >> bits
  self.nbits -= bits
  entry >> 4
}

///|
/// RFC 7932's variable-length code for 0..255 (section 9.2).
fn Decoder::read_var_len8(self : Decoder) -> Int32 raise Stop {
  if self.read_bits(1) == 0 {
    return 0
  }
  let n = self.read_bits(3)
  if n == 0 {
    1
  } else {
    (1 << n) + self.read_bits(n)
  }
}

///|
/// Skips to the next byte boundary; the skipped bits must be zero.
fn Decoder::skip_padding(self : Decoder) -> Unit raise Stop {
  let pad = self.nbits & 7
  if (self.acc & ((1 << pad) - 1)) != 0 {
    raise corrupt("non-zero padding bits")
  }
  self.acc = self.acc >> pad
  self.nbits -= pad
}

///|
/// The next byte-aligned input byte. The caller checks that one is there:
/// `nbits >= 8`, or a byte left in `stash`.
fn Decoder::next_aligned_byte(self : Decoder) -> Byte {
  if self.nbits < 8 {
    self.load_byte() |> ignore
  }
  let b = (self.acc & 0xff).to_byte()
  self.acc = self.acc >> 8
  self.nbits -= 8
  b
}

// ---- window ----

///|
/// Bytes that can be written before pending output must be handed out.
fn Decoder::free_space(self : Decoder) -> Int32 {
  if self.ring.length() == self.ring_max {
    self.ring_max - self.pending
  } else {
    self.ring_max - self.wpos
  }
}

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
/// Writes one byte; `ensure_space` has made room.
fn Decoder::put(self : Decoder, b : Byte) -> Unit {
  self.ring[self.wpos] = b
  self.advance(1)
}

///|
fn Decoder::advance(self : Decoder, n : Int32) -> Unit {
  self.wpos += n
  if self.wpos == self.ring_max {
    self.wpos = 0
  }
  self.pending += n
  self.filled = (self.filled + n).min(self.window)
}

///|
/// The byte `back` positions before the write position (1 or 2), zero
/// before the start of the stream.
fn Decoder::last_byte(self : Decoder, back : Int32) -> Int32 {
  self.ring[(self.wpos - back) & (self.ring.length() - 1)].to_int()
}

///|
/// Copies `n` bytes from `dist` back; `ensure_space(n)` has made room.
fn Decoder::copy_back(self : Decoder, dist : Int32, n : Int32) -> Unit {
  let ring = self.ring
  let cap = ring.length()
  let mut remaining = n
  while remaining > 0 {
    let src = (self.wpos - dist) & (cap - 1)
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
fn Decoder::run(self : Decoder) -> Status raise BrotliError {
  for ;; {
    self.checkpoint()
    let status = self.unit() catch {
      NeedInput => {
        self.rewind()
        return NeedMoreInput
      }
      Fail(kind, message) => raise BrotliError(kind, message)
    }
    if status is Some(status) {
      return status
    }
  }
}

///|
/// One unit, or several where a state loops by itself; `Some` stops the run.
fn Decoder::unit(self : Decoder) -> Status? raise Stop {
  match self.state {
    StreamHeader => self.stream_header()
    MetaHeader => self.meta_header()
    Metadata => return self.metadata()
    Uncompressed => return self.uncompressed()
    NumBlockTypes => self.num_block_types()
    BlockTypeCode =>
      if self.read_code() {
        self.code.start(NUM_BLOCK_COUNT_CODES, self.count_codes[self.cat], 0)
        self.state = BlockCountCode
      }
    BlockCountCode => if self.read_code() { self.state = FirstBlockCount }
    FirstBlockCount => {
      self.block_len[self.cat] = self.read_block_count(self.cat)
      self.next_category()
    }
    DistanceParams => self.distance_params()
    ContextModes => self.context_mode()
    NumTrees => self.num_trees()
    ContextMapHeader => self.context_map_header()
    ContextMapCode => if self.read_code() { self.state = ContextMapEntries }
    ContextMapEntries => self.context_map_entry()
    ContextMapImtf => self.context_map_imtf()
    TreeCodes => self.tree_code()
    CommandStart => self.command()
    Literals => return self.literals()
    Distance => return self.distance()
    Copy => return self.copy()
    MetaDone =>
      if self.is_last {
        self.skip_padding()
        self.state = Done
      } else {
        self.state = MetaHeader
      }
    Done => return Some(Done)
  }
  None
}
