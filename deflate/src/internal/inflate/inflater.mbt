// The raw DEFLATE decoder.
//
// The stream is decoded in small atomic units, as the Brotli decoder does: a
// block header, the stored block's lengths, the counts of a dynamic header,
// one code-length code length, one code length (or repeat), one literal, one
// match. A unit reads all its bits before it changes any state; when the input
// runs out inside one, it raises `NeedInput`, the bit reader rewinds to the
// unit's start, and the few bytes of the unfinished unit (at most 5) are kept
// in `stash` so that the caller may drop the whole chunk. The bit reader takes
// a byte only when a unit needs its bits, so between units it holds fewer
// than 8: it never takes a whole byte past the end of the stream, and what
// follows the stream is `input[last_consumed():]`.
//
// Decoded bytes go to a 32 KiB ring, the window, and are copied out to the
// caller's slice, so that output can be handed out in slices of any size and
// the fast path (fast.mbt) runs whatever their size. A preset dictionary is a
// view of the caller's bytes, read where a distance reaches before the
// output; it is never copied. An error is kept in `failure` and raised once
// the output decoded before it is handed out, so that it comes after the
// same output whatever the split.
//
// The decoder stops right after the final block: `Done` comes once its output
// is all out, and nothing past it is consumed. What may follow is the
// caller's to judge: the root package raises `TrailingData`, zlib and gzip
// read their trailer.

///|
priv enum State {
  /// BFINAL and BTYPE.
  BlockHeader
  /// A stored block's LEN and NLEN, after the padding to a byte.
  StoredHeader
  /// A stored block's bytes, `stored_left` of them still to copy.
  Stored
  /// HLIT, HDIST and HCLEN.
  TableSizes
  /// The code-length code's lengths, `index` of `ncode` read.
  CodeLengthLengths
  /// The literal/length and distance code lengths, `index` of
  /// `nlen + ndist` read.
  CodeLengths
  /// Literals and matches, up to the end of the block.
  Codes
  /// The final block has ended.
  Done
}

///|
/// The window of RFC 1951: distances reach at most 32 KiB back.
const WINDOW_SIZE : Int32 = 32768

///|
const WINDOW_MASK : Int32 = WINDOW_SIZE - 1

///|
/// The most bytes one unit writes: a match of 258.
const MAX_MATCH : Int32 = 258

///|
/// Room for the bytes of an unfinished unit. The longest unit, a match, needs
/// at most 48 bits beyond the fewer than 8 held, 6 bytes, so at most 5 are
/// kept when it is cut short.
const STASH_SIZE : Int32 = 8

///|
/// Why a unit stopped early.
priv suberror Stop {
  /// The unit needs bits the input does not have yet.
  NeedInput
  /// The stream is refused.
  Fail(@codec.ErrorKind, String)
}

///|
/// A streaming raw DEFLATE decoder (RFC 1951) that ends right after the final
/// block. It holds the 32 KiB window and the tables of the current block,
/// never the whole input or output.
pub struct Inflater {
  // Bit reader. `acc` holds `nbits` unread bits, least significant first,
  // and zeros above them; they come from `stash` and then from `view`.
  priv mut acc : Int32
  priv mut nbits : Int32
  priv stash : FixedArray[Byte]
  priv mut stash_len : Int32
  priv mut stash_pos : Int32
  priv mut view : BytesView
  priv mut in_pos : Int32
  // The bit reader at the start of the current unit.
  priv mut save_acc : Int32
  priv mut save_nbits : Int32
  priv mut save_stash_pos : Int32
  priv mut save_in_pos : Int32
  // The caller's output for the current step.
  priv mut out : MutArrayView[Byte]
  priv mut fixed_out : FixedArray[Byte]?
  priv mut out_pos : Int32
  priv empty_out : FixedArray[Byte]
  // The window: `pending` bytes before `wpos` are not handed out yet, and
  // `filled` is how far back a distance may reach into the output,
  // min(output, 32 KiB). Until 32 KiB are out, `wpos` is the output so far.
  priv ring : FixedArray[Byte]
  priv mut wpos : Int32
  priv mut pending : Int32
  priv mut filled : Int32
  // The preset dictionary's last 32 KiB, empty without one.
  priv mut dictionary : BytesView
  // Stream state.
  priv mut state : State
  priv mut last : Bool
  priv mut failure : @codec.CodecError?
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
  // The current block's tables: the fixed ones, shared, or this decoder's.
  priv mut lit : FixedArray[Int32]
  priv mut dist : FixedArray[Int32]
  priv own_lit : FixedArray[Int32]
  priv own_dist : FixedArray[Int32]
  // Building a dynamic block's tables.
  priv raw : FixedArray[UInt16]
  priv lit_builder : @huffman.Builder
  priv dist_builder : @huffman.Builder
  priv lit_lengths : FixedArray[Int32]
  priv dist_lengths : FixedArray[Int32]
  priv cl_lengths : FixedArray[Int32]
  priv counts : FixedArray[Int32]
  priv mut nlen : Int32
  priv mut ndist : Int32
  priv mut ncode : Int32
  priv mut index : Int32
  priv mut prev_len : Int32
  // A stored block.
  priv mut stored_left : Int32
}

///|
/// A decoder at the start of a stream without a dictionary.
pub fn Inflater::new() -> Inflater {
  let empty_out = FixedArray::make(0, b'\x00')
  let own_lit = FixedArray::make(literal_table_size, 0)
  let own_dist = FixedArray::make(distance_table_size, 0)
  {
    acc: 0,
    nbits: 0,
    stash: FixedArray::make(STASH_SIZE, b'\x00'),
    stash_len: 0,
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
    ring: FixedArray::make(WINDOW_SIZE, b'\x00'),
    wpos: 0,
    pending: 0,
    filled: 0,
    dictionary: b""[:],
    state: BlockHeader,
    last: false,
    failure: None,
    step_consumed: 0,
    step_produced: 0,
    lit: own_lit,
    dist: own_dist,
    own_lit,
    own_dist,
    raw: FixedArray::make(literal_table_size, 0),
    lit_builder: @huffman.Builder(root_bits=LITERAL_ROOT_BITS, max_alphabet=286),
    dist_builder: @huffman.Builder(
      root_bits=DISTANCE_ROOT_BITS,
      max_alphabet=30,
    ),
    lit_lengths: FixedArray::make(286, 0),
    dist_lengths: FixedArray::make(30, 0),
    cl_lengths: FixedArray::make(19, 0),
    counts: FixedArray::make(16, 0),
    nlen: 0,
    ndist: 0,
    ncode: 0,
    index: 0,
    prev_len: 0,
    stored_left: 0,
  }
}

///|
/// Starts a new stream, whose matches may reach back into `dictionary`, at
/// most its last 32 KiB, as if it had been decoded just before the stream.
/// The decoder keeps a view of those bytes, not a copy.
pub fn Inflater::reset(self : Inflater, dictionary? : BytesView) -> Unit {
  self.acc = 0
  self.nbits = 0
  self.stash_len = 0
  self.stash_pos = 0
  self.release_step()
  self.wpos = 0
  self.pending = 0
  self.filled = 0
  self.dictionary = match dictionary {
    Some(d) => d[(d.length() - WINDOW_SIZE).max(0):]
    None => b""[:]
  }
  self.state = BlockHeader
  self.last = false
  self.failure = None
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// Bytes the decoder holds: the window, its tables and the scratch space it
/// builds them with, the code lengths and the bytes kept for a unit cut short.
/// All of it is allocated when the decoder is made, so this is the same from
/// the first step to the last. A dictionary is the caller's bytes, kept by
/// reference, and not counted; nor are the fixed codes' tables, which every
/// decoder shares.
pub fn Inflater::memory_usage(self : Inflater) -> Int32 {
  self.ring.length() +
  self.stash.length() +
  4 * (self.own_lit.length() + self.own_dist.length()) +
  2 * self.raw.length() +
  self.lit_builder.memory_usage() +
  self.dist_builder.memory_usage() +
  4 *
  (
    self.lit_lengths.length() +
    self.dist_lengths.length() +
    self.cl_lengths.length() +
    self.counts.length()
  )
}

///|
/// The view of the dictionary the decoder reads: the last 32 KiB of the
/// one `reset` was given, empty without one.
pub fn Inflater::dictionary(self : Inflater) -> BytesView {
  self.dictionary
}

///|
/// Input bytes the latest `step` accepted: all of them on `NeedMoreInput`,
/// up to the end of the stream on `Done`, and up to the error for a step
/// that raised.
pub fn Inflater::last_consumed(self : Inflater) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote, a step that raised included.
pub fn Inflater::last_produced(self : Inflater) -> Int32 {
  self.step_produced
}

///|
/// Decodes from `input` into `output`. `Done` comes once the final block has
/// ended and its output is all out; nothing past it is consumed. With `end`,
/// a stream cut short raises `Truncated` once the output before the cut is
/// out. An error comes after all the output before it: when `output` fills
/// first, the step answers `NeedMoreOutput` and a later one hands out the
/// rest and raises. After an error the decoder raises it again, consuming
/// and writing nothing, until `reset`.
pub fn Inflater::step(
  self : Inflater,
  input : BytesView,
  output : MutArrayView[Byte],
  end~ : Bool,
) -> @codec_bytes.Status raise @codec.CodecError {
  self.step_with(input, output, None, end~)
}

///|
/// `step` into a whole `FixedArray`, with bulk copies.
pub fn Inflater::step_into(
  self : Inflater,
  input : BytesView,
  output : FixedArray[Byte],
  end~ : Bool,
) -> @codec_bytes.Status raise @codec.CodecError {
  self.step_with(input, output.mut_view(), Some(output), end~)
}

///|
fn Inflater::step_with(
  self : Inflater,
  input : BytesView,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  end~ : Bool,
) -> @codec_bytes.Status raise @codec.CodecError {
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
      let kept = self.stash_len - self.stash_pos
      let more = self.view.length() - self.in_pos
      guard kept + more <= STASH_SIZE else {
        abort("an unfinished unit holds more than its bytes")
      }
      FixedArray::unsafe_blit(self.stash, 0, self.stash, self.stash_pos, kept)
      self.stash.blit_from_bytesview(kept, self.view[self.in_pos:])
      self.stash_len = kept + more
      self.stash_pos = 0
      self.in_pos = self.view.length()
      if end {
        return self.fail(
          @codec.CodecError(Truncated, "the DEFLATE data ends early"),
        )
      }
      self.drain()
      self.finish_step(if self.pending > 0 { NeedMoreOutput } else { status })
    }
    Done | NeedMoreOutput => {
      self.drain()
      self.finish_step(if self.pending > 0 { NeedMoreOutput } else { status })
    }
  }
}

///|
fn Inflater::finish_step(
  self : Inflater,
  status : @codec_bytes.Status,
) -> @codec_bytes.Status {
  if self.stash_pos > 0 {
    let kept = self.stash_len - self.stash_pos
    FixedArray::unsafe_blit(self.stash, 0, self.stash, self.stash_pos, kept)
    self.stash_len = kept
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
fn Inflater::fail(
  self : Inflater,
  err : @codec.CodecError,
) -> @codec_bytes.Status raise @codec.CodecError {
  self.failure = Some(err)
  self.stash_len = 0
  self.stash_pos = 0
  self.drain()
  self.finish_failed(err)
}

///|
/// Ends a step after the error `err`: `NeedMoreOutput` while output from
/// before it is pending, then `err`, with the step's counts.
fn Inflater::finish_failed(
  self : Inflater,
  err : @codec.CodecError,
) -> @codec_bytes.Status raise @codec.CodecError {
  let status = self.finish_step(NeedMoreOutput)
  if self.pending > 0 {
    return status
  }
  raise err
}

///|
/// Drops the caller's buffers so a suspended decoder holds neither.
fn Inflater::release_step(self : Inflater) -> Unit {
  self.view = b""[:]
  self.in_pos = 0
  self.out = self.empty_out.mut_view()
  self.fixed_out = None
  self.out_pos = 0
}

// ---- bit reader ----

///|
fn Inflater::checkpoint(self : Inflater) -> Unit {
  self.save_acc = self.acc
  self.save_nbits = self.nbits
  self.save_stash_pos = self.stash_pos
  self.save_in_pos = self.in_pos
}

///|
fn Inflater::rewind(self : Inflater) -> Unit {
  self.acc = self.save_acc
  self.nbits = self.save_nbits
  self.stash_pos = self.save_stash_pos
  self.in_pos = self.save_in_pos
}

///|
/// Moves the next input byte into `acc`; false when there is none.
fn Inflater::load_byte(self : Inflater) -> Bool {
  let byte = if self.stash_pos < self.stash_len {
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
/// The next `n` bits (at most 16), taking only the bytes they need.
fn Inflater::read_bits(self : Inflater, n : Int32) -> Int32 raise Stop {
  while self.nbits < n {
    if !self.load_byte() {
      raise NeedInput
    }
  }
  let v = self.acc & ((1 << n) - 1)
  self.acc = self.acc >> n
  self.nbits -= n
  v
}

///|
/// The next code of `table`, whose root indexes `root_bits` bits: its
/// decorated entry. The bits past the input read as zeros, so a code is
/// known once the bits really there cover its length, and a byte is taken
/// only while they do not, as zlib does.
fn Inflater::read_entry(
  self : Inflater,
  table : FixedArray[Int32],
  root_bits : Int32,
) -> Int32 raise Stop {
  for ;; {
    let mut entry = table[self.acc & ((1 << root_bits) - 1)]
    if (entry & KIND_MASK) == KIND_LINK {
      let sub = (self.acc >> root_bits) & ((1 << ((entry >> 4) & 15)) - 1)
      entry = table[(entry >> 16) + sub]
    }
    let n = entry & 15
    if n <= self.nbits {
      self.acc = self.acc >> n
      self.nbits -= n
      return entry
    }
    if !self.load_byte() {
      raise NeedInput
    }
  }
}

///|
/// Drops the bits up to the next byte boundary, all of those held.
fn Inflater::align(self : Inflater) -> Unit {
  self.acc = 0
  self.nbits = 0
}

// ---- window ----

///|
/// Makes room for `k` more bytes in the window, handing out pending output;
/// false when the caller's slice is full first.
fn Inflater::ensure_space(self : Inflater, k : Int32) -> Bool {
  if WINDOW_SIZE - self.pending >= k {
    return true
  }
  self.drain()
  WINDOW_SIZE - self.pending >= k
}

///|
/// Writes one byte; `ensure_space` has made room.
fn Inflater::put(self : Inflater, b : Byte) -> Unit {
  self.ring[self.wpos] = b
  self.wpos = (self.wpos + 1) & WINDOW_MASK
  self.pending += 1
  if self.filled < WINDOW_SIZE {
    self.filled += 1
  }
}

///|
/// Copies `length` bytes from `distance` back, from the window or, before
/// the output, from the dictionary; `ensure_space(length)` has made room.
fn Inflater::copy_match(
  self : Inflater,
  distance : Int32,
  length : Int32,
) -> Unit raise Stop {
  if distance > self.filled + self.dictionary.length() {
    raise Fail(Corrupt, "a distance reaches before the start of the data")
  }
  let dictionary = self.dictionary
  for _ in 0..<length {
    // Before 32 KiB are out, the window has not wrapped and the output so
    // far starts at 0.
    let back = distance - self.filled
    let b = if back > 0 {
      dictionary[dictionary.length() - back]
    } else {
      self.ring[(self.wpos - distance) & WINDOW_MASK]
    }
    self.put(b)
  }
}

///|
/// Hands out as much pending output as the caller's slice takes.
fn Inflater::drain(self : Inflater) -> Unit {
  let n = self.pending.min(self.out.length() - self.out_pos)
  guard n > 0 else { return }
  let read = (self.wpos - self.pending) & WINDOW_MASK
  let first = n.min(WINDOW_SIZE - read)
  self.write_out(read, first)
  self.write_out(0, n - first)
  self.pending -= n
}

///|
fn Inflater::write_out(self : Inflater, start : Int32, n : Int32) -> Unit {
  match self.fixed_out {
    Some(out) => FixedArray::unsafe_blit(out, self.out_pos, self.ring, start, n)
    None =>
      for i in 0..<n {
        self.out[self.out_pos + i] = self.ring[start + i]
      }
  }
  self.out_pos += n
}

///|
/// The input bytes kept aside for a unit the input cut short: at most 5.
pub fn Inflater::kept_bytes(self : Inflater) -> Int32 {
  self.stash_len - self.stash_pos
}
