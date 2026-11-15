// The streaming decoder.
//
// Suspension model (as in gaato/deflate's raw DEFLATE decoder): the stream
// is decoded in small atomic units (a header field, one code length, one
// command, one literal). A unit reads all its bits before it changes any
// state; when the input runs out mid-unit it raises `NeedInput`, the bit
// reader rewinds to the unit's start, and the at most few bytes of the
// unfinished unit are kept in `stash` so the caller may drop the whole
// chunk. Decoded bytes go to the sliding window and are copied out to the
// caller's buffer, so output can be handed out in slices of any size. An
// error is kept in `failure` and raised once the output decoded before it is
// handed out, so that it comes after the same output whatever the split.

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
  DictionaryCopy
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
  priv until : @codec_bytes.Until
  // The LZ77 dictionary distances past the window address, and where the
  // copy from it goes on.
  priv dictionary : Dictionary?
  priv mut dict_at : Int32
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
  priv mut failure : @codec.CodecError?
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
  priv builder : @huffman.Builder
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
/// A decoder at the start of a stream. It refuses a stream whose window
/// exceeds what `max_window_bits` allows: `LimitExceeded` with the
/// `Memory` resource, where `needed` is the stream's window and `limit` the
/// largest one allowed, both `(1 << WBITS) - 16` bytes (RFC 7932 section
/// 9.1). The default 24 accepts every RFC 7932 stream. Values are clamped
/// to 10..24.
///
/// Brotli has no framing: an input holds one stream. With `until` at its
/// default `EndOfInput`, bytes after the stream raise `TrailingData`; with
/// `EndOfMember`, `step` answers `Done` right after the stream's last
/// meta-block and consumes nothing past it, so `input[last_consumed():]`
/// is what follows the stream.
///
/// With `dictionary`, the stream may copy from it as RFC 9841 section 3.2
/// has it, as RFC 9842's `dcb` coding does: distances just past the
/// window's reach (the output so far, or the window once it is full)
/// address the dictionary from its end, and the static dictionary's words
/// come after them. A copy that would run past the dictionary's end raises
/// `Corrupt`, as the reference decoder (google/brotli) refuses it: RFC 9841
/// has it go on into the window, which a full window no longer holds. The
/// decoder keeps the dictionary by reference, so the bytes it is a view of
/// stay alive as long as the decoder, and `memory_usage` does not count
/// them.
pub fn Decoder::Decoder(
  max_window_bits~ : Int32 = 24,
  until~ : @codec_bytes.Until = EndOfInput,
  dictionary? : Dictionary,
) -> Decoder {
  let empty_out = FixedArray::make(0, b'\x00')
  {
    max_window_bits: max_window_bits.clamp(min=10, max=24),
    until,
    dictionary,
    dict_at: 0,
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
    builder: table_builder(),
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
/// Bytes the decoder holds: the window and the prefix code tables of the
/// largest meta-block so far, which grow with the stream, and what is
/// allocated with the decoder (the context maps, the trees' offsets, the
/// code reader's and the table builder's scratch space), 27,793 bytes. At
/// most `1 << max_window_bits` plus 1,343,596 bytes of tables plus those
/// (see RESOURCE_BOUNDS.md). `reset` releases the window and keeps the
/// tables. The static dictionary, shared by every decoder, and an LZ77
/// dictionary, the caller's bytes kept by reference, are not counted.
pub fn Decoder::memory_usage(self : Decoder) -> Int32 {
  let mut entries = self.lit_trees.pool.length() +
    self.cmd_trees.pool.length() +
    self.dist_trees.pool.length() +
    self.map_code.pool.length() +
    self.code.cl_code.pool.length()
  for c in 0..<3 {
    entries += self.type_codes[c].pool.length() +
      self.count_codes[c].pool.length()
  }
  self.ring.length() + 2 * entries + self.fixed_memory()
}

///|
/// The bytes of what is allocated with the decoder, whatever the stream.
fn Decoder::fixed_memory(self : Decoder) -> Int32 {
  let mut offsets = self.map_code.offsets.length() +
    self.lit_trees.offsets.length() +
    self.cmd_trees.offsets.length() +
    self.dist_trees.offsets.length() +
    self.code.cl_code.offsets.length()
  for c in 0..<3 {
    offsets += self.type_codes[c].offsets.length() +
      self.count_codes[c].offsets.length()
  }
  self.lit_context_map.length() +
  self.dist_context_map.length() +
  self.word.length() +
  4 *
  (
    offsets +
    self.context_modes.length() +
    self.num_types.length() +
    self.block_type.length() +
    self.prev_block_type.length() +
    self.block_len.length() +
    self.dist_ring.length() +
    self.code.cl_lengths.length() +
    self.code.lengths.length() +
    self.code.counts.length()
  ) +
  self.builder.memory_usage()
}

///|
/// Decodes from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used. `end` says whether `input`
/// holds the last bytes there are: then a stream cut short raises
/// `Truncated` instead of asking for more. With `EndOfInput`, `Done` comes
/// once the stream has ended, `end` is true and every byte is consumed;
/// bytes after the end of the stream raise `TrailingData`. With
/// `EndOfMember`, `Done` comes once the stream has ended, and the bytes
/// after it are left unconsumed.
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
  match status {
    NeedMoreInput => {
      // Keep the unfinished unit's bytes; the caller may drop the chunk.
      let kept = self.stash[self.stash_pos:].to_owned()
      kept.push_iter(self.view[self.in_pos:].iter())
      self.stash = kept
      self.stash_pos = 0
      self.in_pos = self.view.length()
      if end {
        let message = if self.state is StreamHeader && kept.length() == 0 {
          "the input holds no stream"
        } else {
          "the input ends inside the stream"
        }
        return self.fail(@codec.CodecError(Truncated, message))
      }
      self.drain()
      self.finish_step(if self.pending > 0 { NeedMoreOutput } else { status })
    }
    Done => {
      // Under `EndOfMember` the stream's end gave back the bytes past it.
      if self.until is EndOfInput &&
        (
          self.nbits > 0 ||
          self.stash_pos < self.stash.length() ||
          self.in_pos < self.view.length()
        ) {
        // The stream ends on a byte boundary, where the whole bytes in `acc`
        // begin, if in this step's input.
        self.in_pos = (self.in_pos - self.nbits / 8).max(0)
        return self.fail(
          @codec.CodecError(TrailingData, "data after the last meta-block"),
        )
      }
      self.drain()
      self.finish_step(
        if self.pending > 0 {
          NeedMoreOutput
        } else if end || self.until is EndOfMember {
          Done
        } else {
          // More input could still be trailing data.
          NeedMoreInput
        },
      )
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
/// Records a terminal error, hands out the output before it, and raises it
/// once that is all out.
fn Decoder::fail(
  self : Decoder,
  err : @codec.CodecError,
) -> Status raise @codec.CodecError {
  self.failure = Some(err)
  self.stash = []
  self.stash_pos = 0
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
  let at = self.in_pos
  if self.nbits <= 23 &&
    self.stash_pos >= self.stash.length() &&
    self.view.length() - at >= 3 {
    // The bytes the loop below would load, `(31 - nbits) / 8` of them (at
    // most 3), straight from the view: it holds them.
    let view = self.view
    let mut acc = self.acc
    let mut nbits = self.nbits
    acc = acc | (view.unsafe_get(at).to_int() << nbits)
    nbits += 8
    let mut used = 1
    if nbits <= 23 {
      acc = acc | (view.unsafe_get(at + 1).to_int() << nbits)
      nbits += 8
      used = 2
      if nbits <= 23 {
        acc = acc | (view.unsafe_get(at + 2).to_int() << nbits)
        nbits += 8
        used = 3
      }
    }
    self.acc = acc
    self.nbits = nbits
    self.in_pos = at + used
    return
  }
  while self.nbits <= 23 && self.load_byte() {

  }
}

///|
/// The next `n` (at most 24) bits.
#inline
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
/// The next `n` (at most 24) bits, left unread.
#inline
fn Decoder::peek_bits(self : Decoder, n : Int32) -> Int32 raise Stop {
  if self.nbits < n {
    self.refill()
    if self.nbits < n {
      raise NeedInput
    }
  }
  self.acc & ((1 << n) - 1)
}

///|
/// Drops `n` bits that `peek_bits` has made sure are there.
#inline
fn Decoder::drop_bits(self : Decoder, n : Int32) -> Unit {
  self.acc = self.acc >> n
  self.nbits -= n
}

///|
/// The next symbol of tree `tree` of `group`.
#inline
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
  // The entries are within the tree's table, as `Group::build` lays it out.
  let mut entry = pool.unsafe_get(base + (self.acc & (ROOT_SIZE - 1))).to_int()
  let mut bits = entry & 15
  if bits > ROOT_BITS {
    let sub = (self.acc >> ROOT_BITS) & ((1 << (bits - ROOT_BITS)) - 1)
    entry = pool.unsafe_get(base + (entry >> 4) + sub).to_int()
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

///|
/// Returns the whole bytes left in `acc` to the input, at the end of the
/// stream: they follow it. They all come from `view`: a unit leaves bytes in
/// `stash` only when they fall short of what it needs, so they all belong
/// to the stream, and the stream ends on a byte boundary.
fn Decoder::give_back(self : Decoder) -> Unit {
  self.in_pos -= self.nbits / 8
  self.acc = 0
  self.nbits = 0
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
    Some(out) => @blit.bytes(out, self.out_pos, self.ring, start, n)
    None => @blit.into_view(self.out, self.out_pos, self.ring, start, n)
  }
  self.out_pos += n
}

// ---- the state machine ----

///|
/// Runs units until the input or the output runs out or the stream ends.
fn Decoder::run(self : Decoder) -> Status raise @codec.CodecError {
  for ;; {
    self.checkpoint()
    let status = self.unit() catch {
      NeedInput => {
        self.rewind()
        return NeedMoreInput
      }
      Fail(kind, message) => raise @codec.CodecError(kind, message)
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
        self.code.start(
          @rules.NUM_BLOCK_COUNT_CODES,
          self.count_codes[self.cat],
          0,
        )
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
    CommandStart => return self.commands()
    Literals => return self.literals()
    Distance => return self.distance()
    Copy => return self.copy()
    DictionaryCopy => return self.dictionary_copy()
    MetaDone =>
      if self.is_last {
        self.skip_padding()
        self.state = Done
        if self.until is EndOfMember {
          self.give_back()
        }
      } else {
        self.state = MetaHeader
      }
    Done => return Some(Done)
  }
  None
}
