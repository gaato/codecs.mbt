// The raw DEFLATE encoder: libdeflate's levels 1 to 9 (1.24, deflate_compress.c)
// made streaming, with zlib's sync flush and preset dictionaries.
//
// Input is copied into `buf`, which holds the 32 KiB window, the block being
// parsed and `LOOKAHEAD` bytes past where the parser is. The parser (parse.mbt)
// chooses literals and matches into the sequence store and counts symbols;
// a block ends after `soft_max` bytes, when the store fills, or where the
// symbol statistics change (libdeflate's block splitting). The block is then
// written (block.mbt), whole, into `out`, the output waiting for the caller,
// and the window slides down so that the next block has room.
//
// Splitting does not matter (rule 5 of CONTRACT.md): what the parser decides
// depends only on the bytes, the options and where flushes fall, never on
// how much input a step brings or how much output it takes.
// - Every decision that libdeflate takes from the end of its input (how long
//   a match may be near the end, whether a block may still be split, how
//   much to scan for the minimum match length, whether a matchfinder can
//   insert a position) looks at most 5,602 bytes ahead of the position the
//   parser stands at when a step of it begins (`LOOKAHEAD` below). The parser
//   steps only with that much input waiting, or once the end of the segment
//   (the next flush, or the end of the stream) is known, and then takes the
//   decisions from the real end. So both ways give the same answers.
// - Blocks end by input bytes and statistics, never by output room; a block
//   is written whole into `out` only once the caller has taken the one
//   before, and handing it out only copies it.
// - The window moves by whole blocks, and the matchfinders count positions
//   from a base that moves with the bytes.
// - libdeflate's rule that a block within 5,000 bytes of the end of the input
//   takes those bytes along needs to see a whole block ahead, and is left
//   out: a stream may end in a short block.
// - After a flush, the matchfinder inserts the positions it had to leave
//   out before the flush, once the next bytes come (`catch_up`), and the
//   parser starts the next segment's first block afresh.
//
// libdeflate compresses a buffer that it holds whole; with the same bytes,
// no dictionary and no flush, this encoder writes what libdeflate 1.24
// writes when built with blocks of at most 65,535 bytes
// (`SOFT_MAX_BLOCK_LENGTH` and `FAST_SOFT_MAX_BLOCK_LENGTH`), 16,384
// sequences (`SEQ_STORE_LENGTH`) and no 5,000-byte tail rule, but for the
// empty stream, which libdeflate stores and this encoder writes as zlib
// does. The SHA-256 that src/encode_wbtest.mbt pins were checked against it.

///|
/// The window: how far back a match may reach.
const WINDOW : Int32 = @lz77.WINDOW

///|
/// What the parser needs ahead of where a step of it begins, unless the end
/// is known (see above): a lazy parser's chain of better matches moves at
/// most 344 bytes past it (each better match raises 4 × length − ⌊log2
/// offset⌋, between −2 and 1,032, by at least 3), the last match takes 258
/// more, and from there block splitting looks 5,000 bytes ahead; the
/// matchfinders read at most 262 bytes past where they search.
const LOOKAHEAD : Int32 = 6144

///|
/// The most bytes a lazy parser's block runs past `soft_max`: from a
/// position just before it, a chain of better matches (344 bytes) and a
/// match (258). The other parsers' blocks run at most a match past it.
const MAX_OVERRUN : Int32 = 602

///|
/// libdeflate's MIN_BLOCK_LENGTH: block splitting leaves blocks shorter than
/// this alone, and does not split within this distance of the end.
const MIN_BLOCK_LENGTH : Int32 = 5000

///|
/// The blocks of levels 1 to 9 end after this many bytes, so that a stored
/// one is one stored block: 65,535. libdeflate's levels 2 to 9 allow
/// 300,000; with block splitting, 65,535 came out within 0.1% of that on
/// Silesia and Canterbury, for a fifth of the memory.
const SOFT_MAX_BLOCK_LENGTH : Int32 = 65535

///|
/// Sequences (a run of literals and the match after it) in a block of
/// levels 2 to 9: libdeflate's 50,000 is for 300,000-byte blocks; Silesia and
/// Canterbury came out the same with 12,000.
const SEQ_STORE_LENGTH : Int32 = 16384

///|
/// Sequences in a block of level 1, libdeflate's FAST_SEQ_STORE_LENGTH.
const FAST_SEQ_STORE_LENGTH : Int32 = 8192

///|
/// A stored block holds at most this many bytes.
const MAX_STORED_LENGTH : Int32 = 65535

///|
/// How libdeflate parses at each level.
priv enum Strategy {
  /// Level 0: stored blocks only.
  Stored
  /// Level 1: the hash-table matchfinder, greedy, fixed blocks.
  Fastest
  /// Levels 2 to 4: hash chains, the longest match at each position.
  Greedy
  /// Levels 5 to 7: a match is taken only if the next position has no
  /// better one.
  Lazy
  /// Levels 8 and 9: the next two positions are tried.
  Lazy2
}

///|
/// What a step of the parser ended with.
priv enum Parsed {
  /// It needs more input, or the end of the segment, to go on.
  NeedInput
  /// A block is complete, from `block_begin` to `in_next`.
  BlockDone
  /// The parser is at the end of the segment, every block of it complete.
  SegmentDone
}

///|
/// A streaming raw DEFLATE encoder (RFC 1951) that ends right after the final
/// block. It holds the window, a block and its output, and the matchfinder's
/// tables, never the whole input or output.
pub struct Deflater {
  // Options.
  priv strategy : Strategy
  priv max_search_depth : Int32
  priv nice_match_length : Int32
  // A stream of at most this many bytes, with no dictionary or flush, is
  // stored as it is, as libdeflate does.
  priv max_passthrough : Int32
  priv soft_max : Int32
  priv seq_cap : Int32
  priv dictionary : BytesView
  // Input: bytes before `avail`; the parser is at `in_next`, in the block
  // that begins at `block_begin`; `end` is where the segment ends (-1 until
  // a flush or the end of the stream says), `ending` how.
  priv buf : FixedArray[Byte]
  priv mut avail : Int32
  priv mut in_next : Int32
  priv mut block_begin : Int32
  priv mut end : Int32
  priv mut finishing : Bool
  // Matchfinders: the one of the level, reset for each stream at its first
  // block.
  priv hc : @lz77.HcMatchfinder?
  priv ht : @lz77.HtMatchfinder?
  priv mut mf_ready : Bool
  // The parser in the current block.
  priv mut in_block : Bool
  priv mut block_ready : Bool
  priv mut block_stored : Bool
  priv mut min_len : Int32
  priv mut next_recalc : Int32
  priv mut max_len : Int32
  priv mut nice_len : Int32
  // Block splitting: observations of the block so far, and of the latest
  // ones not merged in yet.
  priv observations : FixedArray[UInt32]
  priv new_observations : FixedArray[UInt32]
  priv mut num_observations : UInt32
  priv mut num_new_observations : UInt32
  // Symbol counts and the sequences: for each, a literal run in bits 0 to
  // 16, the match length after it in bits 17 to 25 (0 in the last), the
  // offset slot in bits 26 to 30, and the offset in `seq_offset`.
  priv litlen_freqs : FixedArray[Int32]
  priv offset_freqs : FixedArray[Int32]
  priv seq_litlen : FixedArray[Int32]
  priv seq_offset : FixedArray[UInt16]
  priv mut nseq : Int32
  priv used_literals : FixedArray[Bool]
  // The block's codes and what building them takes (block.mbt).
  priv maker : @huffman.CodeMaker?
  priv litlen_lens : FixedArray[Int32]
  priv litlen_codes : FixedArray[Int32]
  priv offset_lens : FixedArray[Int32]
  priv offset_codes : FixedArray[Int32]
  priv all_lens : FixedArray[Int32]
  priv precode_freqs : FixedArray[Int32]
  priv precode_lens : FixedArray[Int32]
  priv precode_codes : FixedArray[Int32]
  priv precode_items : FixedArray[Int32]
  priv len_full_codes : FixedArray[Int32]
  priv len_full_lens : FixedArray[Int32]
  // Output: complete bytes in `out[out_drained:out_pos]` wait for the
  // caller, and `bitcount` bits (fewer than 8 between blocks) in `bits`.
  priv out : FixedArray[Byte]
  priv mut out_pos : Int32
  priv mut out_drained : Int32
  priv mut bits : UInt32
  priv mut bitcount : Int32
  // The stream: whether input came since the last flush (or none was
  // made), whether anything was written, whether the final block is.
  priv mut need_flush : Bool
  priv mut started : Bool
  priv mut final_written : Bool
  priv mut finished : Bool
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
}

///|
/// An encoder at the start of a stream. `level` is clamped to 0 to 9 and
/// chooses libdeflate's strategy and search settings for that level. Matches
/// may reach back into `dictionary` as if it had come just before the
/// stream: the encoder keeps a view of its last 32 KiB and copies them into
/// the window at the start of every stream.
pub fn Deflater::new(level~ : Int32, dictionary? : BytesView) -> Deflater {
  let level = level.clamp(min=0, max=9)
  let (strategy, depth, nice) : (Strategy, Int32, Int32) = match level {
    0 => (Stored, 0, 0)
    1 => (Fastest, 0, 32)
    2 => (Greedy, 6, 10)
    3 => (Greedy, 12, 14)
    4 => (Greedy, 16, 30)
    5 => (Lazy, 16, 30)
    6 => (Lazy, 35, 65)
    7 => (Lazy, 100, 130)
    8 => (Lazy2, 300, MAX_MATCH_LEN)
    _ => (Lazy2, 600, MAX_MATCH_LEN)
  }
  let dictionary = match dictionary {
    Some(d) => d[(d.length() - WINDOW).max(0):]
    None => b""[:]
  }
  let seq_cap = match strategy {
    Stored => 0
    Fastest => FAST_SEQ_STORE_LENGTH
    _ => SEQ_STORE_LENGTH
  }
  let (buf_size, soft_max) = match strategy {
    // A stored block, and one byte to see whether the stream goes on.
    Stored => (MAX_STORED_LENGTH + 1, MAX_STORED_LENGTH)
    _ => (WINDOW + SOFT_MAX_BLOCK_LENGTH + LOOKAHEAD, SOFT_MAX_BLOCK_LENGTH)
  }
  let max_block = match strategy {
    Stored => MAX_STORED_LENGTH
    Fastest | Greedy => soft_max - 1 + MAX_MATCH_LEN
    Lazy | Lazy2 => soft_max - 1 + MAX_OVERRUN
  }
  // A block's output costs no more than storing it: its bytes, 5 for each
  // stored block (LEN, NLEN and the header's byte), and one more for the
  // byte that the bits before the first header may take. The empty blocks of
  // a flush and of the end are written alone, and take less.
  let out_size = max_block +
    5 * ((max_block + MAX_STORED_LENGTH - 1) / MAX_STORED_LENGTH) +
    1
  let parses = !(strategy is Stored)
  let n = if parses { NUM_LITLEN_SYMS } else { 0 }
  let d : Deflater = {
    strategy,
    max_search_depth: depth,
    nice_match_length: nice,
    max_passthrough: 55 - level * 4,
    soft_max,
    seq_cap,
    dictionary,
    buf: FixedArray::make(buf_size, b'\x00'),
    avail: 0,
    in_next: 0,
    block_begin: 0,
    end: -1,
    finishing: false,
    hc: if strategy is (Greedy | Lazy | Lazy2) {
      Some(@lz77.HcMatchfinder())
    } else {
      None
    },
    ht: if strategy is Fastest {
      Some(@lz77.HtMatchfinder())
    } else {
      None
    },
    mf_ready: false,
    in_block: false,
    block_ready: false,
    block_stored: false,
    min_len: MIN_MATCH_LEN,
    next_recalc: 0,
    max_len: MAX_MATCH_LEN,
    nice_len: nice,
    observations: FixedArray::make(if parses { 10 } else { 0 }, 0),
    new_observations: FixedArray::make(if parses { 10 } else { 0 }, 0),
    num_observations: 0,
    num_new_observations: 0,
    litlen_freqs: FixedArray::make(n, 0),
    offset_freqs: FixedArray::make(if parses { NUM_OFFSET_SYMS } else { 0 }, 0),
    seq_litlen: FixedArray::make(if parses { seq_cap + 1 } else { 0 }, 0),
    seq_offset: FixedArray::make(if parses { seq_cap + 1 } else { 0 }, 0),
    nseq: 0,
    used_literals: FixedArray::make(if parses { 256 } else { 0 }, false),
    maker: if parses {
      Some(@huffman.CodeMaker(max_alphabet=NUM_LITLEN_SYMS))
    } else {
      None
    },
    litlen_lens: FixedArray::make(n, 0),
    litlen_codes: FixedArray::make(n, 0),
    offset_lens: FixedArray::make(if parses { NUM_OFFSET_SYMS } else { 0 }, 0),
    offset_codes: FixedArray::make(if parses { NUM_OFFSET_SYMS } else { 0 }, 0),
    all_lens: FixedArray::make(
      if parses {
        NUM_LITLEN_SYMS + NUM_OFFSET_SYMS
      } else {
        0
      },
      0,
    ),
    precode_freqs: FixedArray::make(
      if parses {
        NUM_PRECODE_SYMS
      } else {
        0
      },
      0,
    ),
    precode_lens: FixedArray::make(if parses { NUM_PRECODE_SYMS } else { 0 }, 0),
    precode_codes: FixedArray::make(
      if parses {
        NUM_PRECODE_SYMS
      } else {
        0
      },
      0,
    ),
    precode_items: FixedArray::make(
      if parses {
        NUM_LITLEN_SYMS + NUM_OFFSET_SYMS
      } else {
        0
      },
      0,
    ),
    len_full_codes: FixedArray::make(
      if parses {
        MAX_MATCH_LEN + 1
      } else {
        0
      },
      0,
    ),
    len_full_lens: FixedArray::make(
      if parses {
        MAX_MATCH_LEN + 1
      } else {
        0
      },
      0,
    ),
    out: FixedArray::make(out_size, b'\x00'),
    out_pos: 0,
    out_drained: 0,
    bits: 0,
    bitcount: 0,
    need_flush: true,
    started: false,
    final_written: false,
    finished: false,
    step_consumed: 0,
    step_produced: 0,
  }
  d.reset()
  d
}

///|
/// Starts a new stream with the same level and dictionary.
pub fn Deflater::reset(self : Deflater) -> Unit {
  // Stored blocks have no matches to reach the dictionary.
  let n = if self.strategy is Stored { 0 } else { self.dictionary.length() }
  self.buf.blit_from_bytesview(0, self.dictionary[:n])
  self.avail = n
  self.in_next = n
  self.block_begin = n
  self.end = -1
  self.finishing = false
  self.mf_ready = false
  self.in_block = false
  self.block_ready = false
  self.block_stored = false
  self.nseq = 0
  self.out_pos = 0
  self.out_drained = 0
  self.bits = 0
  self.bitcount = 0
  self.need_flush = true
  self.started = false
  self.final_written = false
  self.finished = false
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// The bytes the encoder holds, the same from the first step to the last:
/// the input buffer, the output buffer, the matchfinder's tables, the
/// sequence store and the block's counts and codes. The dictionary is the
/// caller's bytes, kept by reference, and not counted.
pub fn Deflater::memory_usage(self : Deflater) -> Int32 {
  let mf = match (self.hc, self.ht) {
    (Some(hc), _) => hc.memory_usage()
    (_, Some(ht)) => ht.memory_usage()
    _ => 0
  }
  let ints = self.litlen_freqs.length() +
    self.offset_freqs.length() +
    self.seq_litlen.length() +
    self.litlen_lens.length() +
    self.litlen_codes.length() +
    self.offset_lens.length() +
    self.offset_codes.length() +
    self.all_lens.length() +
    self.precode_freqs.length() +
    self.precode_lens.length() +
    self.precode_codes.length() +
    self.precode_items.length() +
    self.len_full_codes.length() +
    self.len_full_lens.length() +
    self.observations.length() +
    self.new_observations.length()
  self.buf.length() +
  self.out.length() +
  mf +
  4 * ints +
  2 * self.seq_offset.length() +
  self.used_literals.length() +
  (match self.maker {
    Some(maker) => maker.memory_usage()
    None => 0
  })
}

///|
/// The dictionary's bytes the encoder keeps a view of: its last 32 KiB.
pub fn Deflater::dictionary(self : Deflater) -> BytesView {
  self.dictionary
}

///|
/// The bytes in the input buffer (the window included) and the output bytes
/// waiting for the caller: what the resource bounds limit.
pub fn Deflater::waiting(self : Deflater) -> (Int32, Int32) {
  (self.avail, self.out_pos - self.out_drained)
}

///|
/// The sizes of the input buffer and of the output buffer.
pub fn Deflater::capacities(self : Deflater) -> (Int32, Int32) {
  (self.buf.length(), self.out.length())
}

///|
/// Whether the stream has ended and all its output has been handed out.
pub fn Deflater::is_finished(self : Deflater) -> Bool {
  self.finished
}

///|
/// Input bytes the latest `step` took.
pub fn Deflater::last_consumed(self : Deflater) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote.
pub fn Deflater::last_produced(self : Deflater) -> Int32 {
  self.step_produced
}

///|
/// Compresses from `input` into `output`, as `@deflate.Encoder::step`
/// describes: `Flush` is a sync flush, `Finish` ends the stream, and both
/// apply once all of `input` is taken.
pub fn Deflater::step(
  self : Deflater,
  input : BytesView,
  output : MutArrayView[Byte],
  action~ : @codec_bytes.EncodeAction,
) -> @codec_bytes.Status {
  self.step_consumed = 0
  self.step_produced = 0
  if self.finished {
    return Done
  }
  let mut taken = 0
  let mut produced = 0
  for ;; {
    // Hand out what waits; nothing more is written until all of it is out.
    let n = (self.out_pos - self.out_drained).min(output.length() - produced)
    for i in 0..<n {
      output[produced + i] = self.out[self.out_drained + i]
    }
    self.out_drained += n
    produced += n
    if self.out_drained < self.out_pos {
      return self.finish_step(NeedMoreOutput, taken, produced)
    }
    self.out_pos = 0
    self.out_drained = 0
    if self.final_written {
      self.finished = true
      return self.finish_step(Done, taken, produced)
    }
    if self.block_ready {
      self.write_block()
      continue
    }
    if self.end < 0 {
      let n = (input.length() - taken).min(self.buf.length() - self.avail)
      if n > 0 {
        self.buf.blit_from_bytesview(self.avail, input[taken:taken + n])
        self.avail += n
        taken += n
        self.need_flush = true
      }
      if taken == input.length() {
        match action {
          Finish => {
            self.end = self.avail
            self.finishing = true
          }
          Flush if self.need_flush => self.end = self.avail
          _ => ()
        }
      }
    }
    match self.parse() {
      BlockDone => self.block_ready = true
      SegmentDone => self.end_segment()
      NeedInput => {
        if taken == input.length() {
          return self.finish_step(NeedMoreInput, taken, produced)
        }
        // With the buffer full, a block is always complete (see LOOKAHEAD).
        guard self.avail < self.buf.length() else {
          abort("Deflater: the input buffer is full with no block complete")
        }
      }
    }
  }
}

///|
/// `step` into a whole `FixedArray`.
pub fn Deflater::step_into(
  self : Deflater,
  input : BytesView,
  output : FixedArray[Byte],
  action~ : @codec_bytes.EncodeAction,
) -> @codec_bytes.Status {
  self.step(input, output.mut_view(), action~)
}

///|
fn Deflater::finish_step(
  self : Deflater,
  status : @codec_bytes.Status,
  consumed : Int32,
  produced : Int32,
) -> @codec_bytes.Status {
  self.step_consumed = consumed
  self.step_produced = produced
  status
}

///|
/// Writes the block the parser completed, and moves the window down.
fn Deflater::write_block(self : Deflater) -> Unit {
  let begin = self.block_begin
  let length = self.in_next - begin
  let is_final = self.finishing && self.in_next == self.end
  if self.block_stored {
    self.write_stored(begin, length, is_final)
  } else {
    self.finish_block(begin, length, is_final)
  }
  self.block_ready = false
  self.started = true
  if is_final {
    self.align()
    self.final_written = true
  }
  self.slide()
}

///|
/// Moves the bytes down so that only the window before `in_next` (none at
/// level 0) is kept before it.
fn Deflater::slide(self : Deflater) -> Unit {
  let keep = if self.strategy is Stored { 0 } else { WINDOW }
  let delta = self.in_next - keep
  guard delta > 0 else { return }
  FixedArray::unsafe_blit(self.buf, 0, self.buf, delta, self.avail - delta)
  self.avail -= delta
  self.in_next -= delta
  self.block_begin -= delta
  if self.end >= 0 {
    self.end -= delta
  }
  match (self.hc, self.ht) {
    (Some(hc), _) => hc.move_down(delta)
    (_, Some(ht)) => ht.move_down(delta)
    _ => ()
  }
}

///|
/// The parser is at the end of a segment: a flush's empty stored block, or
/// the empty final block of a stream whose last segment had no bytes.
fn Deflater::end_segment(self : Deflater) -> Unit {
  if self.finishing {
    if self.strategy is Stored {
      self.write_stored(self.in_next, 0, true)
    } else {
      // A fixed block with only its end: 10 bits.
      self.put(1 | (1 << 1), 3)
      self.put(
        static_litlen_codes[END_OF_BLOCK],
        static_litlen_lens[END_OF_BLOCK],
      )
    }
    self.align()
    self.final_written = true
  } else {
    self.put(0, 3)
    self.align()
    self.put(0, 16)
    self.put(0xFFFF, 16)
    self.need_flush = false
  }
  self.started = true
  self.end = -1
}

///|
/// Writes the low `n` (at most 16) bits of `value`.
fn Deflater::put(self : Deflater, value : Int32, n : Int32) -> Unit {
  self.bits = self.bits | (value.reinterpret_as_uint() << self.bitcount)
  self.bitcount += n
  while self.bitcount >= 8 {
    self.out[self.out_pos] = self.bits.to_byte()
    self.out_pos += 1
    self.bits = self.bits >> 8
    self.bitcount -= 8
  }
}

///|
/// Pads with zero bits to the next byte boundary.
fn Deflater::align(self : Deflater) -> Unit {
  if self.bitcount > 0 {
    self.put(0, 8 - self.bitcount)
  }
}

///|
/// Writes `data[begin:begin + length]` as stored blocks of at most 65,535
/// bytes, the last one final if `is_final`; an empty one if `length` is 0.
fn Deflater::write_stored(
  self : Deflater,
  begin : Int32,
  length : Int32,
  is_final : Bool,
) -> Unit {
  let end = begin + length
  let mut p = begin
  for ;; {
    let len = (end - p).min(MAX_STORED_LENGTH)
    let last = p + len == end
    self.put(if last && is_final { 1 } else { 0 }, 3)
    self.align()
    self.put(len, 16)
    self.put(len ^ 0xFFFF, 16)
    FixedArray::unsafe_blit(self.out, self.out_pos, self.buf, p, len)
    self.out_pos += len
    p += len
    if last {
      break
    }
  }
}
