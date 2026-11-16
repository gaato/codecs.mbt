// libdeflate 1.24 deflate_compress_near_optimal, made resumable. Its match
// cache contains packed (length, offset) pairs and a (count, literal) trailer
// per byte. Rewinding a split retains the already-scanned tail, its matches
// and its new statistics; the finder never inserts those positions twice.
// The costs and optimization passes are in near_cost.mbt.
// Length/count occupies nine low bits, offset/literal the upper bits. All
// entries fit 24 bits, keeping the large JS cache in the 31-bit Smi range.

///|
// Upstream's build-time lower bound: MIN_BLOCK_LENGTH * MAX_MATCHES_PER_POS.
// Smaller caches can end blocks below 5000 bytes and invalidate stored_bound.
const MATCH_CACHE_LENGTH : Int32 = MIN_BLOCK_LENGTH * 256

///|
const NEAR_NODE_COUNT : Int32 = SOFT_MAX_BLOCK_LENGTH + MIN_BLOCK_LENGTH

///|
priv struct NearState {
  finder : @lz77.BtMatchfinder
  matches : FixedArray[Int32]
  cache : FixedArray[Int32]
  node_cost : FixedArray[UInt32]
  node_item : FixedArray[Int32]
  costs : FixedArray[Int32]
  saved_costs : FixedArray[Int32]
  prev_observations : FixedArray[UInt32]
  new_lengths : FixedArray[Int32]
  lengths : FixedArray[Int32]
  max_passes : Int32
  min_improvement : Int32
  min_saved_bits : Int32
  max_static : Int32
  mut finder_next : Int32
  mut cache_len : Int32
  mut emit_cache_len : Int32
  mut emit_end : Int32
  mut scan_next : Int32
  mut prev_check : Int32
  mut next_observation : Int32
  mut prev_num_observations : UInt32
  mut only_literals : Bool
  mut rewind : Bool
  mut first : Bool
}

///|
fn NearState::new(level : Int32, max_distance : Int32) -> NearState {
  let (passes, improvement, saved, max_static) = match level {
    10 => (2, 32, 32, 0)
    11 => (4, 16, 16, 1000)
    _ => (10, 1, 1, 10000)
  }
  {
    finder: @lz77.BtMatchfinder(max_distance~),
    matches: FixedArray::make(512, 0),
    cache: FixedArray::make(MATCH_CACHE_LENGTH + 256 + 257, 0),
    node_cost: FixedArray::make(NEAR_NODE_COUNT, 0),
    node_item: FixedArray::make(NEAR_NODE_COUNT, 0),
    costs: FixedArray::make(547, 0),
    saved_costs: FixedArray::make(547, 0),
    prev_observations: FixedArray::make(10, 0),
    new_lengths: FixedArray::make(259, 0),
    lengths: FixedArray::make(259, 0),
    max_passes: passes,
    min_improvement: improvement,
    min_saved_bits: saved,
    max_static,
    finder_next: 0,
    cache_len: 0,
    emit_cache_len: 0,
    emit_end: 0,
    scan_next: 0,
    prev_check: -1,
    next_observation: 0,
    prev_num_observations: 0,
    only_literals: false,
    rewind: false,
    first: true,
  }
}

///|
fn NearState::reset(self : NearState) -> Unit {
  self.finder.reset()
  self.finder_next = 0
  self.cache_len = 0
  self.emit_cache_len = 0
  self.emit_end = 0
  self.scan_next = 0
  self.prev_check = -1
  self.next_observation = 0
  self.prev_num_observations = 0
  self.only_literals = false
  self.rewind = false
  self.first = true
  self.new_lengths.fill(0)
  self.lengths.fill(0)
  self.prev_observations.fill(0)
  self.costs.fill(0)
  self.saved_costs.fill(0)
}

///|
fn NearState::memory_usage(self : NearState) -> Int32 {
  self.finder.memory_usage().to_int() +
  4 *
  (
    self.matches.length() +
    self.cache.length() +
    self.node_cost.length() +
    self.node_item.length() +
    self.costs.length() +
    self.saved_costs.length() +
    self.prev_observations.length() +
    self.new_lengths.length() +
    self.lengths.length()
  )
}

///|
fn Deflater::near_merge_stats(self : Deflater, n : NearState) -> Unit {
  self.merge_new_observations()
  for i in 0..<259 {
    n.lengths[i] += n.new_lengths[i]
    n.new_lengths[i] = 0
  }
}

///|
fn Deflater::parse_near(self : Deflater, n : NearState) -> Parsed {
  let known = self.end >= 0
  let end = if known { self.end } else { self.avail }
  let stop = if known { end } else { self.avail - LOOKAHEAD + 1 }
  if !self.in_block {
    if known && self.in_next == end {
      return SegmentDone
    }
    if self.in_next >= stop {
      return NeedInput
    }
    if !self.started &&
      self.finishing &&
      self.dictionary.length() == 0 &&
      end - self.in_next <= self.max_passthrough {
      self.block_begin = self.in_next
      self.in_next = end
      self.block_stored = true
      return BlockDone
    }
    if !self.mf_ready {
      self.mf_ready = true
      n.finder_next = 0
    }
    // Catch up the dictionary and the last four positions before a flush.
    // Already-inserted positions in a rewound cache never go through this.
    while n.finder_next < self.in_next && end - n.finder_next >= 5 {
      n.finder.skip_byte(
        self.buf,
        n.finder_next,
        self.nice_match_length.min(end - n.finder_next),
        self.max_search_depth,
      )
      n.finder_next += 1
    }
    self.block_begin = self.in_next
    self.block_stored = false
    self.in_block = true
    n.prev_check = -1
    n.next_observation = self.in_next
    self.min_len = if n.only_literals {
      259
    } else {
      self.calculate_min_match_len(
        self.block_begin,
        self.soft_max.min(end - self.block_begin),
      )
    }
  }
  let block_end = self.block_end(end)
  for ;; {
    if self.in_next >= stop {
      return NeedInput
    }
    let pos = self.in_next
    let max_len = (end - pos).min(258)
    let nice = self.nice_match_length.min(max_len)
    let count = if max_len >= 5 {
      let count = n.finder.get_matches(
        self.buf,
        pos,
        max_len,
        nice,
        self.max_search_depth,
        n.matches,
      )
      n.finder_next = pos + 1
      count
    } else {
      0
    }
    let best_len = if count > 0 { n.matches[2 * count - 2] } else { 0 }
    for i in 0..<count {
      n.cache[n.cache_len] = n.matches[2 * i] | (n.matches[2 * i + 1] << 9)
      n.cache_len += 1
    }
    n.cache[n.cache_len] = count | (self.buf[pos].to_int() << 9)
    n.cache_len += 1
    if pos >= n.next_observation {
      if best_len >= self.min_len {
        self.observe_match(best_len)
        n.next_observation = pos + best_len
        n.new_lengths[best_len] += 1
      } else {
        self.observe_literal(self.buf[pos])
        n.next_observation = pos + 1
      }
    }
    self.in_next += 1
    if best_len >= 3 && best_len >= nice {
      for _ in 0..<(best_len - 1) {
        let pos = self.in_next
        let remaining = end - pos
        if remaining >= 5 {
          n.finder.skip_byte(
            self.buf,
            pos,
            self.nice_match_length.min(remaining),
            self.max_search_depth,
          )
          n.finder_next = pos + 1
        }
        n.cache[n.cache_len] = self.buf[pos].to_int() << 9
        n.cache_len += 1
        self.in_next += 1
      }
    }
    let mut changed = false
    if self.in_next < block_end && n.cache_len < MATCH_CACHE_LENGTH {
      if self.num_new_observations < 512U ||
        self.in_next - self.block_begin < 5000 ||
        end - self.in_next < 5000 {
        continue
      }
      if self.do_end_block_check(self.in_next - self.block_begin) {
        changed = true
      } else {
        self.near_merge_stats(n)
        n.prev_check = self.in_next
        continue
      }
    }
    n.rewind = changed && n.prev_check >= 0
    n.emit_end = if n.rewind { n.prev_check } else { self.in_next }
    n.emit_cache_len = n.cache_len
    if n.rewind {
      for _ in n.emit_end..<self.in_next {
        n.emit_cache_len -= 1
        n.emit_cache_len -= n.cache[n.emit_cache_len] & 511
      }
    } else {
      self.near_merge_stats(n)
    }
    return BlockDone
  }
}

///|
fn Deflater::near_write_block(self : Deflater, n : NearState) -> Unit {
  let length = n.emit_end - self.block_begin
  let is_final = self.finishing && n.emit_end == self.end
  self.near_optimize(n, length, is_final)
  self.block_ready = false
  self.started = true
  n.first = false
  if is_final {
    self.align()
    self.final_written = true
  }
  for i in 0..<10 {
    n.prev_observations[i] = self.observations[i]
  }
  n.prev_num_observations = self.num_observations
  if n.rewind {
    let remaining = n.cache_len - n.emit_cache_len
    for i in 0..<remaining {
      n.cache[i] = n.cache[n.emit_cache_len + i]
    }
    n.cache_len = remaining
    self.observations.fill(0)
    self.num_observations = 0
    n.lengths.fill(0)
    n.prev_check = -1
    n.next_observation = self.in_next
    self.min_len = if n.only_literals {
      259
    } else {
      self.calculate_min_match_len(
        n.emit_end,
        self.soft_max.min(
          (if self.end >= 0 { self.end } else { self.avail }) - n.emit_end,
        ),
      )
    }
  } else {
    n.cache_len = 0
    self.in_block = false
    self.observations.fill(0)
    self.new_observations.fill(0)
    self.num_observations = 0
    self.num_new_observations = 0
    n.lengths.fill(0)
    n.new_lengths.fill(0)
  }
  // Retain the window before the emitted end, including all bytes needed by
  // a rewound block, while keeping the finder's scan frontier further ahead.
  n.scan_next = self.in_next
  self.in_next = n.emit_end
  self.block_begin = n.emit_end
  let before = self.in_next
  self.slide()
  let delta = before - self.in_next
  n.next_observation -= delta
  self.in_next = n.scan_next
}
