// Port of libdeflate 1.24 deflate_compress.c's near-optimal cost model,
// minimum-cost path and optimization passes. See near_default_costs.mbt for
// the upstream license and its exact integer default literal-cost tables.

///|
const COST_LENGTH : Int32 = 256

///|
const COST_OFFSET : Int32 = 515

///|
// Upstream uses 0x80000000. This smaller forbidden cost fits a 31-bit Smi
// and is still greater than any valid path: each literal costs at most
// 14*16, and NEAR_NODE_COUNT*224 = 15,799,840 < 2^29. Adding one edge to it
// stays within the Smi range too. Thus no forbidden edge can beat literals.
const NEAR_FORBIDDEN_COST : UInt32 = 0x20000000U

///|
fn Deflater::near_make_codes(self : Deflater) -> Unit {
  let maker = self.maker.unwrap()
  maker.make(
    self.litlen_freqs,
    NUM_LITLEN_SYMS,
    MAX_LITLEN_CODEWORD_LEN,
    self.litlen_lens,
    self.litlen_codes,
  )
  maker.make(
    self.offset_freqs,
    NUM_OFFSET_SYMS,
    MAX_OFFSET_CODEWORD_LEN,
    self.offset_lens,
    self.offset_codes,
  )
}

///|
fn Deflater::near_all_literals(self : Deflater, length : Int32) -> Unit {
  self.litlen_freqs.fill(0)
  self.offset_freqs.fill(0)
  for i in self.block_begin..<(self.block_begin + length) {
    self.litlen_freqs[self.buf[i].to_int()] += 1
  }
  self.litlen_freqs[END_OF_BLOCK] = 1
  self.near_make_codes()
}

///|
fn Deflater::near_true_cost(self : Deflater) -> Int32 {
  let (_, _, _, explicit) = self.precompute_huffman_header()
  let mut cost = 5 + 5 + 4 + 3 * explicit
  for sym in 0..<19 {
    cost += self.precode_freqs[sym] *
      (self.precode_lens[sym] + extra_precode_bits[sym])
  }
  for sym in 0..<257 {
    cost += self.litlen_freqs[sym] * self.litlen_lens[sym]
  }
  for slot in 0..<29 {
    cost += self.litlen_freqs[257 + slot] *
      (self.litlen_lens[257 + slot] + extra_length_bits[slot])
  }
  for slot in 0..<30 {
    cost += self.offset_freqs[slot] *
      (self.offset_lens[slot] + extra_offset_bits[slot])
  }
  cost
}

///|
fn NearState::costs_from_codes(
  self : NearState,
  litlen : FixedArray[Int32],
  offsets : FixedArray[Int32],
) -> Unit {
  for lit in 0..<256 {
    self.costs[lit] = (if litlen[lit] != 0 { litlen[lit] } else { 13 }) * 16
  }
  for len in 3..<=258 {
    let slot = length_slot[len]
    let bits = if litlen[257 + slot] != 0 { litlen[257 + slot] } else { 13 }
    self.costs[COST_LENGTH + len] = (bits + extra_length_bits[slot]) * 16
  }
  for slot in 0..<30 {
    let bits = if offsets[slot] != 0 { offsets[slot] } else { 10 }
    self.costs[COST_OFFSET + slot] = (bits + extra_offset_bits[slot]) * 16
  }
}

///|
fn near_adjust_cost(current : Int32, default : Int32, change : Int32) -> Int32 {
  match change {
    0 => (default + 3 * current) / 4
    1 => (default + current) / 2
    2 => (5 * default + 3 * current) / 8
    3 => (3 * default + current) / 4
    _ => default
  }
}

///|
fn Deflater::near_initial_costs(
  self : Deflater,
  n : NearState,
  length : Int32,
) -> Unit {
  self.litlen_freqs.fill(0)
  for i in self.block_begin..<(self.block_begin + length) {
    self.litlen_freqs[self.buf[i].to_int()] += 1
  }
  let cutoff = length >> 11
  let mut used = 0
  for lit in 0..<256 {
    if self.litlen_freqs[lit] > cutoff {
      used += 1
    }
  }
  used = used.max(1)
  let mut literals = length
  let mut matches = 0
  for len in choose_min_match_len(used, self.max_search_depth)..<=258 {
    matches += n.lengths[len]
    literals -= len * n.lengths[len]
  }
  literals = literals.max(0)
  let group = if matches > literals {
    2
  } else if matches * 4 > literals {
    1
  } else {
    0
  }
  let lit_cost = near_literal_costs[group][used]
  let len_cost = match group {
    0 => 109
    1 => 93
    _ => 84
  }
  let change = if n.first {
    4
  } else {
    let mut delta = 0UL
    for i in 0..<10 {
      let prev = n.prev_observations[i].to_uint64() *
        self.num_observations.to_uint64()
      let cur = self.observations[i].to_uint64() *
        n.prev_num_observations.to_uint64()
      delta += if prev > cur { prev - cur } else { cur - prev }
    }
    let cutoff = n.prev_num_observations.to_uint64() *
      self.num_observations.to_uint64() *
      200UL /
      512UL
    if delta > 3UL * cutoff {
      4
    } else if 4UL * delta > 9UL * cutoff {
      3
    } else if 2UL * delta > 3UL * cutoff {
      2
    } else if 2UL * delta > cutoff {
      1
    } else {
      0
    }
  }
  for lit in 0..<256 {
    n.costs[lit] = near_adjust_cost(n.costs[lit], lit_cost, change)
  }
  for len in 3..<=258 {
    let i = COST_LENGTH + len
    n.costs[i] = near_adjust_cost(
      n.costs[i],
      len_cost + extra_length_bits[length_slot[len]] * 16,
      change,
    )
  }
  for slot in 0..<30 {
    let i = COST_OFFSET + slot
    n.costs[i] = near_adjust_cost(
      n.costs[i],
      78 + extra_offset_bits[slot] * 16,
      change,
    )
  }
}

///|
fn Deflater::near_min_cost_path(
  self : Deflater,
  n : NearState,
  length : Int32,
) -> Unit {
  let costs = n.costs
  let nodes = n.node_cost
  let items = n.node_item
  nodes[length] = 0
  let mut cache = n.emit_cache_len
  for pos = length - 1; pos >= 0; pos = pos - 1 {
    cache -= 1
    let count = n.cache[cache] & 511
    let literal = n.cache[cache] >> 9
    let mut best = costs[literal].reinterpret_as_uint() + nodes[pos + 1]
    let mut item = (literal << 9) | 1
    let mut len = 3
    for m in (cache - count)..<cache {
      let match_length = n.cache[m] & 511
      let offset = n.cache[m] >> 9
      let off_cost = costs[COST_OFFSET + offset_slot(offset)]
      while len <= match_length {
        let cost = (off_cost + costs[COST_LENGTH + len]).reinterpret_as_uint() +
          nodes[pos + len]
        if cost < best {
          best = cost
          item = len | (offset << 9)
        }
        len += 1
      }
    }
    cache -= count
    nodes[pos] = best
    items[pos] = item
  }
  self.litlen_freqs.fill(0)
  self.offset_freqs.fill(0)
  for pos = 0; pos < length; {
    let item = items[pos]
    let len = item & 511
    let offset = item >> 9
    if len == 1 {
      self.litlen_freqs[offset] += 1
    } else {
      self.litlen_freqs[257 + length_slot[len]] += 1
      self.offset_freqs[offset_slot(offset)] += 1
    }
    continue pos + len
  }
  self.litlen_freqs[END_OF_BLOCK] = 1
  self.near_make_codes()
}

///|
fn Deflater::near_optimize(
  self : Deflater,
  n : NearState,
  length : Int32,
  is_final : Bool,
) -> Unit {
  self.near_all_literals(length)
  let only_cost = self.near_true_cost()
  for i in length..<=(length - 1 + 258).min(n.node_cost.length() - 1) {
    n.node_cost[i] = NEAR_FORBIDDEN_COST
  }
  let mut static_cost = 0x7fffffff
  if length <= n.max_static {
    for i in 0..<547 {
      n.saved_costs[i] = n.costs[i]
    }
    n.costs_from_codes(static_litlen_lens, static_offset_lens)
    self.near_min_cost_path(n, length)
    static_cost = (n.node_cost[0] / 16U).reinterpret_as_int() + 7
    for i in 0..<547 {
      n.costs[i] = n.saved_costs[i]
    }
  }
  self.near_initial_costs(n, length)
  let mut best = 0x7fffffff
  let mut true_cost = 0
  for _ in 0..<n.max_passes {
    self.near_min_cost_path(n, length)
    true_cost = self.near_true_cost()
    if true_cost + n.min_improvement > best {
      break
    }
    best = true_cost
    for i in 0..<547 {
      n.saved_costs[i] = n.costs[i]
    }
    n.costs_from_codes(self.litlen_lens, self.offset_lens)
  }
  n.only_literals = false
  if only_cost.min(static_cost) < best {
    if only_cost < static_cost {
      self.near_all_literals(length)
      n.costs_from_codes(self.litlen_lens, self.offset_lens)
      n.only_literals = true
    } else {
      n.costs_from_codes(static_litlen_lens, static_offset_lens)
      self.near_min_cost_path(n, length)
    }
  } else if true_cost >= best + n.min_saved_bits {
    for i in 0..<547 {
      n.costs[i] = n.saved_costs[i]
    }
    self.near_min_cost_path(n, length)
    n.costs_from_codes(self.litlen_lens, self.offset_lens)
  }
  // Reuse the existing block writer. This conversion does not retally or
  // rebuild the codes chosen above, including the all-literals alternative.
  self.nseq = 0
  self.seq_litlen[0] = 0
  if n.only_literals {
    self.seq_litlen[0] = length
  } else {
    for pos = 0; pos < length; {
      let item = n.node_item[pos]
      let len = item & 511
      if len == 1 {
        self.seq_litlen[self.nseq] += 1
      } else {
        let offset = item >> 9
        self.seq_litlen[self.nseq] = self.seq_litlen[self.nseq] |
          (len << 17) |
          (offset_slot(offset) << 26)
        self.seq_offset[self.nseq] = offset.to_uint16()
        self.nseq += 1
        self.seq_litlen[self.nseq] = 0
      }
      continue pos + len
    }
  }
  self.flush_block(self.block_begin, length, is_final)
}
