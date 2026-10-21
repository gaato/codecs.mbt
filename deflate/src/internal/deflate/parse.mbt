// The parsers, ported from libdeflate's deflate_compress.c (1.24):
// deflate_compress_fastest, _greedy and _lazy_generic, with block splitting
// and the minimum match length heuristic, made resumable. A step of a parser
// begins only at a position with `LOOKAHEAD` bytes after it, or once the end
// of the segment is known (deflater.mbt says why that keeps the output
// independent of the split); it stops before a position without them, with
// its state in the encoder's fields, and goes on there the next time.
//
// Where libdeflate reads the end of its input, these read `in_end`: the end
// of the segment once it is known, else the end of the bytes in the buffer,
// which is then at least `LOOKAHEAD` away, so that each test comes out as
// it would with the real end.

///|
/// Observation types of block splitting: 8 for literals, 2 for matches.
const NUM_LITERAL_OBSERVATION_TYPES : Int32 = 8

///|
const NUM_OBSERVATION_TYPES : Int32 = 10

///|
const NUM_OBSERVATIONS_PER_BLOCK_CHECK : UInt32 = 512

///|
/// libdeflate's map from the number of different literals in use to the
/// minimum match length worth taking; 3 for 80 and more.
let min_lens : FixedArray[Int32] = [
  9, 9, 9, 9, 9, 9, 8, 8, 7, 7, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
  5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4, 4,
  4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
]

///|
fn choose_min_match_len(
  num_used_literals : Int32,
  max_search_depth : Int32,
) -> Int32 {
  if num_used_literals >= min_lens.length() {
    return MIN_MATCH_LEN
  }
  let min_len = min_lens[num_used_literals]
  // With a shallow search, long matches are hard to find. libdeflate takes
  // at most 4 below a depth of 5, which no level of its parsers has.
  if max_search_depth < 10 {
    min_len.min(5)
  } else if max_search_depth < 16 {
    min_len.min(7)
  } else {
    min_len
  }
}

///|
/// The minimum match length from the literals in the first 4 KiB of the
/// block's `length` bytes from `begin`; 3 for a block under 512 bytes.
fn Deflater::calculate_min_match_len(
  self : Deflater,
  begin : Int32,
  length : Int32,
) -> Int32 {
  if length < 512 {
    return MIN_MATCH_LEN
  }
  let used = self.used_literals
  used.fill(false)
  for i in begin..<(begin + length.min(4096)) {
    used[self.buf[i].to_int()] = true
  }
  let mut n = 0
  for i in 0..<256 {
    if used[i] {
      n += 1
    }
  }
  choose_min_match_len(n, self.max_search_depth)
}

///|
/// The minimum match length from the literals the block has used so far,
/// leaving out those used rarely.
fn Deflater::recalculate_min_match_len(self : Deflater) -> Int32 {
  let freqs = self.litlen_freqs
  let mut literal_freq = 0
  for i in 0..<256 {
    literal_freq += freqs[i]
  }
  let cutoff = literal_freq >> 10
  let mut n = 0
  for i in 0..<256 {
    if freqs[i] > cutoff {
      n += 1
    }
  }
  choose_min_match_len(n, self.max_search_depth)
}

///|
/// Starts a block at `in_next`: empty counts and sequences, and the
/// statistics of block splitting.
fn Deflater::begin_block(self : Deflater, in_next : Int32) -> Unit {
  self.block_begin = in_next
  self.litlen_freqs.fill(0)
  self.offset_freqs.fill(0)
  self.nseq = 0
  self.seq_litlen[0] = 0
  self.observations.fill(0)
  self.new_observations.fill(0)
  self.num_observations = 0
  self.num_new_observations = 0
  self.max_len = MAX_MATCH_LEN
  self.nice_len = self.nice_match_length
  self.in_block = true
}

///|
#inline
fn Deflater::choose_literal(self : Deflater, literal : Byte) -> Unit {
  let lit = literal.to_int()
  self.litlen_freqs[lit] += 1
  self.seq_litlen[self.nseq] += 1
}

///|
#inline
fn Deflater::observe_literal(self : Deflater, literal : Byte) -> Unit {
  let lit = literal.to_int()
  self.new_observations[((lit >> 5) & 0x6) | (lit & 1)] += 1
  self.num_new_observations += 1
}

///|
#inline
fn Deflater::choose_match(
  self : Deflater,
  length : Int32,
  offset : Int32,
) -> Unit {
  let slot = offset_slot(offset)
  self.litlen_freqs[FIRST_LEN_SYM + length_slot[length]] += 1
  self.offset_freqs[slot] += 1
  let i = self.nseq
  self.seq_litlen[i] = self.seq_litlen[i] | (length << 17) | (slot << 26)
  self.seq_offset[i] = offset.to_uint16()
  self.nseq = i + 1
  self.seq_litlen[i + 1] = 0
}

///|
#inline
fn Deflater::observe_match(self : Deflater, length : Int32) -> Unit {
  self.new_observations[NUM_LITERAL_OBSERVATION_TYPES +
  (if length >= 9 { 1 } else { 0 })] += 1
  self.num_new_observations += 1
}

///|
fn Deflater::merge_new_observations(self : Deflater) -> Unit {
  for i in 0..<NUM_OBSERVATION_TYPES {
    self.observations[i] += self.new_observations[i]
    self.new_observations[i] = 0
  }
  self.num_observations += self.num_new_observations
  self.num_new_observations = 0
}

///|
/// Whether the latest observations differ enough from the block's so far
/// to end the block, in libdeflate's 32-bit arithmetic.
fn Deflater::do_end_block_check(self : Deflater, block_length : Int32) -> Bool {
  if self.num_observations > 0 {
    let num_new = self.num_new_observations
    let num_old = self.num_observations
    let mut total_delta : UInt32 = 0
    for i in 0..<NUM_OBSERVATION_TYPES {
      let expected = self.observations[i] * num_new
      let actual = self.new_observations[i] * num_old
      total_delta += if actual > expected {
        actual - expected
      } else {
        expected - actual
      }
    }
    let num_items = num_old + num_new
    let mut cutoff = num_new * 200 / 512 * num_old
    // Very short blocks cost a lot in code headers: split them only when
    // it clearly pays.
    if block_length < 10000 && num_items < 8192 {
      cutoff += (cutoff.to_uint64() * (8192U - num_items).to_uint64() / 8192UL).to_uint()
    }
    if total_delta + (block_length / 4096).reinterpret_as_uint() * num_old >=
      cutoff {
      return true
    }
  }
  self.merge_new_observations()
  false
}

///|
#inline
fn Deflater::should_end_block(
  self : Deflater,
  block_begin : Int32,
  in_next : Int32,
  in_end : Int32,
) -> Bool {
  if self.num_new_observations < NUM_OBSERVATIONS_PER_BLOCK_CHECK ||
    in_next - block_begin < MIN_BLOCK_LENGTH ||
    in_end - in_next < MIN_BLOCK_LENGTH {
    return false
  }
  self.do_end_block_check(in_next - block_begin)
}

///|
/// Parses up to the end of a block, the end of the segment, or the end of
/// the look-ahead.
fn Deflater::parse(self : Deflater) -> Parsed {
  let end_known = self.end >= 0
  let in_end = if end_known { self.end } else { self.avail }
  // A step of the parser may begin at positions before `stop`.
  let stop = if end_known { in_end } else { self.avail - LOOKAHEAD + 1 }
  if !self.in_block {
    let in_next = self.in_next
    if end_known && in_next == in_end {
      return SegmentDone
    }
    if in_next >= stop {
      return NeedInput
    }
    if !self.started &&
      self.finishing &&
      self.dictionary.length() == 0 &&
      in_end - in_next <= self.max_passthrough {
      // A short stream: stored as it is, as libdeflate stores an input of
      // at most `max_passthrough` bytes.
      self.block_begin = in_next
      self.in_next = in_end
      self.block_stored = true
      return BlockDone
    }
    match self.strategy {
      Stored => {
        // A stored block of 65,535 bytes, or what is left of the segment.
        let length = if end_known {
          (in_end - in_next).min(MAX_STORED_LENGTH)
        } else if self.avail - in_next > MAX_STORED_LENGTH {
          MAX_STORED_LENGTH
        } else {
          return NeedInput
        }
        self.block_begin = in_next
        self.in_next = in_next + length
        self.block_stored = true
        return BlockDone
      }
      Fastest => {
        let mf = self.ht.unwrap()
        if !self.mf_ready {
          mf.reset(0)
          self.mf_ready = true
        }
        mf.catch_up(self.buf, in_next, in_end)
      }
      _ => {
        let mf = self.hc.unwrap()
        if !self.mf_ready {
          mf.reset(0)
          self.mf_ready = true
        }
        mf.catch_up(self.buf, in_next, in_end)
      }
    }
    self.block_stored = false
    self.begin_block(in_next)
    if !(self.strategy is Fastest) {
      let block_end = if end_known {
        (in_next + self.soft_max).min(in_end)
      } else {
        in_next + self.soft_max
      }
      self.min_len = self.calculate_min_match_len(in_next, block_end - in_next)
      // libdeflate's in_next + min(in_end - in_next, 10000): the same
      // positions are reached, since a later one would be past the end.
      self.next_recalc = in_next + 10000
    }
  }
  let stop = if end_known { 0x7FFFFFFF } else { stop }
  match self.strategy {
    Fastest => self.parse_fastest(self.ht.unwrap(), in_end, stop)
    Greedy => self.parse_greedy(self.hc.unwrap(), in_end, stop)
    Lazy => self.parse_lazy(self.hc.unwrap(), in_end, stop, false)
    _ => self.parse_lazy(self.hc.unwrap(), in_end, stop, true)
  }
}

///|
/// The end of the current block: `soft_max` bytes on, or the end of the
/// segment.
#inline
fn Deflater::block_end(self : Deflater, in_end : Int32) -> Int32 {
  let end = self.block_begin + self.soft_max
  if self.end >= 0 {
    end.min(in_end)
  } else {
    end
  }
}

///|
/// Level 1: the longest match the hash table offers, or a literal; fixed
/// blocks and no splitting.
fn Deflater::parse_fastest(
  self : Deflater,
  mf : @lz77.HtMatchfinder,
  in_end : Int32,
  stop : Int32,
) -> Parsed {
  let data = self.buf
  let block_end = self.block_end(in_end)
  let seq_cap = self.seq_cap
  let mut in_next = self.in_next
  let mut max_len = self.max_len
  let mut nice_len = self.nice_len
  while true {
    if in_next >= stop {
      self.in_next = in_next
      self.max_len = max_len
      self.nice_len = nice_len
      return NeedInput
    }
    let remaining = in_end - in_next
    if remaining < MAX_MATCH_LEN {
      max_len = remaining
      if max_len < @lz77.REQUIRED_BYTES {
        for _ in 0..<max_len {
          self.choose_literal(data[in_next])
          in_next += 1
        }
        break
      }
      nice_len = nice_len.min(max_len)
    }
    let length = mf.longest_match(data, in_next, max_len, nice_len)
    if length != 0 {
      self.choose_match(length, mf.offset())
      mf.skip_bytes(data, in_next + 1, in_end, length - 1)
      in_next += length
    } else {
      self.choose_literal(data[in_next])
      in_next += 1
    }
    if !(in_next < block_end && self.nseq < seq_cap) {
      break
    }
  }
  self.in_next = in_next
  self.in_block = false
  BlockDone
}

///|
/// Levels 2 to 4: the longest match at each position, if long enough.
fn Deflater::parse_greedy(
  self : Deflater,
  mf : @lz77.HcMatchfinder,
  in_end : Int32,
  stop : Int32,
) -> Parsed {
  let data = self.buf
  let block_begin = self.block_begin
  let block_end = self.block_end(in_end)
  let seq_cap = self.seq_cap
  let depth = self.max_search_depth
  let min_len = self.min_len
  let mut in_next = self.in_next
  let mut max_len = self.max_len
  let mut nice_len = self.nice_len
  while true {
    if in_next >= stop {
      self.in_next = in_next
      self.max_len = max_len
      self.nice_len = nice_len
      return NeedInput
    }
    if in_end - in_next < MAX_MATCH_LEN {
      max_len = in_end - in_next
      nice_len = nice_len.min(max_len)
    }
    let length = mf.longest_match(
      data,
      in_next,
      min_len - 1,
      max_len,
      nice_len,
      depth,
    )
    let offset = mf.offset()
    if length >= min_len && (length > MIN_MATCH_LEN || offset <= 4096) {
      self.choose_match(length, offset)
      self.observe_match(length)
      mf.skip_bytes(data, in_next + 1, in_end, length - 1)
      in_next += length
    } else {
      self.choose_literal(data[in_next])
      self.observe_literal(data[in_next])
      in_next += 1
    }
    if !(in_next < block_end &&
      self.nseq < seq_cap &&
      !self.should_end_block(block_begin, in_next, in_end)) {
      break
    }
  }
  self.in_next = in_next
  self.in_block = false
  BlockDone
}

///|
/// Levels 5 to 9: a match is taken only if the next position (and with
/// `lazy2` the one after) has no better one; a match of 3 bytes more than
/// 8 KiB back is not worth it.
fn Deflater::parse_lazy(
  self : Deflater,
  mf : @lz77.HcMatchfinder,
  in_end : Int32,
  stop : Int32,
  lazy2 : Bool,
) -> Parsed {
  let data = self.buf
  let block_begin = self.block_begin
  let block_end = self.block_end(in_end)
  let seq_cap = self.seq_cap
  let depth = self.max_search_depth
  let mut in_next = self.in_next
  let mut max_len = self.max_len
  let mut nice_len = self.nice_len
  let mut min_len = self.min_len
  let mut next_recalc = self.next_recalc
  while true {
    if in_next >= stop {
      self.in_next = in_next
      self.max_len = max_len
      self.nice_len = nice_len
      self.min_len = min_len
      self.next_recalc = next_recalc
      return NeedInput
    }
    if in_next >= next_recalc {
      min_len = self.recalculate_min_match_len()
      next_recalc += in_next - block_begin
    }
    if in_end - in_next < MAX_MATCH_LEN {
      max_len = in_end - in_next
      nice_len = nice_len.min(max_len)
    }
    let mut cur_len = mf.longest_match(
      data,
      in_next,
      min_len - 1,
      max_len,
      nice_len,
      depth,
    )
    let mut cur_offset = mf.offset()
    if cur_len < min_len || (cur_len == MIN_MATCH_LEN && cur_offset > 8192) {
      self.choose_literal(data[in_next])
      self.observe_literal(data[in_next])
      in_next += 1
    } else {
      in_next += 1
      // libdeflate's `have_cur_match`: a match at in_next - 1.
      while true {
        if cur_len >= nice_len {
          self.choose_match(cur_len, cur_offset)
          self.observe_match(cur_len)
          mf.skip_bytes(data, in_next, in_end, cur_len - 1)
          in_next += cur_len - 1
          break
        }
        if in_end - in_next < MAX_MATCH_LEN {
          max_len = in_end - in_next
          nice_len = nice_len.min(max_len)
        }
        let next_len = mf.longest_match(
          data,
          in_next,
          cur_len - 1,
          max_len,
          nice_len,
          depth >> 1,
        )
        let next_offset = mf.offset()
        in_next += 1
        if next_len >= cur_len &&
          4 * (next_len - cur_len) + (bsr32(cur_offset) - bsr32(next_offset)) >
          2 {
          // A better match at the next position: a literal, and that one.
          self.choose_literal(data[in_next - 2])
          self.observe_literal(data[in_next - 2])
          cur_len = next_len
          cur_offset = next_offset
          continue
        }
        if lazy2 {
          if in_end - in_next < MAX_MATCH_LEN {
            max_len = in_end - in_next
            nice_len = nice_len.min(max_len)
          }
          let next_len = mf.longest_match(
            data,
            in_next,
            cur_len - 1,
            max_len,
            nice_len,
            depth >> 2,
          )
          let next_offset = mf.offset()
          in_next += 1
          if next_len >= cur_len &&
            4 * (next_len - cur_len) + (bsr32(cur_offset) - bsr32(next_offset)) >
            6 {
            // A much better match two positions on: two literals.
            self.choose_literal(data[in_next - 3])
            self.observe_literal(data[in_next - 3])
            self.choose_literal(data[in_next - 2])
            self.observe_literal(data[in_next - 2])
            cur_len = next_len
            cur_offset = next_offset
            continue
          }
          self.choose_match(cur_len, cur_offset)
          self.observe_match(cur_len)
          if cur_len > 3 {
            mf.skip_bytes(data, in_next, in_end, cur_len - 3)
            in_next += cur_len - 3
          }
        } else {
          self.choose_match(cur_len, cur_offset)
          self.observe_match(cur_len)
          mf.skip_bytes(data, in_next, in_end, cur_len - 2)
          in_next += cur_len - 2
        }
        break
      }
    }
    if !(in_next < block_end &&
      self.nseq < seq_cap &&
      !self.should_end_block(block_begin, in_next, in_end)) {
      break
    }
  }
  self.in_next = in_next
  self.in_block = false
  BlockDone
}
