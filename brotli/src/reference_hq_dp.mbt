// Port of google/brotli v1.2.1 c/enc/backward_references_hq.c.
// Copyright 2013 Google Inc.; MIT, see LICENSE-encoder.

///|
priv struct HqDp {
  quality : Int32
  lengths : FixedArray[UInt32]
  distances : FixedArray[Int32]
  inserts : FixedArray[UInt32]
  info : FixedArray[UInt32]
  model : HqCost
  positions : FixedArray[Int32]
  cache : FixedArray[Int32]
  costs : FixedArray[Float]
  differences : FixedArray[Float]
  mut index : Int32
}

///|
fn HqDp::new(length : Int32, quality : Int32) -> HqDp {
  {
    quality,
    lengths: FixedArray::make(length + 1, 1U),
    distances: FixedArray::make(length + 1, 0),
    inserts: FixedArray::make(length + 1, 0U),
    info: FixedArray::make(length + 1, HQ_INFINITY.reinterpret_as_uint()),
    model: HqCost::new(length),
    positions: FixedArray::make(8, 0),
    cache: FixedArray::make(32, 0),
    costs: FixedArray::make(8, (0.0 : Float)),
    differences: FixedArray::make(8, (0.0 : Float)),
    index: 0,
  }
}

///|
fn HqDp::clear(self : HqDp) -> Unit {
  self.lengths.fill(1U)
  self.distances.fill(0)
  self.inserts.fill(0U)
  self.info.fill(HQ_INFINITY.reinterpret_as_uint())
  self.lengths[0] = 0U
  self.info[0] = (0.0 : Float).reinterpret_as_uint()
  self.index = 0
}

///|
fn HqDp::copy_length(self : HqDp, pos : Int32) -> Int32 {
  (self.lengths[pos] & 0x1ffffffU).reinterpret_as_int()
}

///|
fn HqDp::distance_code(self : HqDp, pos : Int32) -> Int32 {
  let code = (self.inserts[pos] >> 27).reinterpret_as_int()
  if code == 0 {
    self.distances[pos] + 15
  } else {
    code - 1
  }
}

///|
fn HqDp::evaluate(
  self : HqDp,
  pos : Int32,
  absolute : UInt32,
  reach : Int32,
  gap : Int32,
  initial : FixedArray[Int32],
) -> Unit {
  // hq_parse evaluates positions in 0..<length, in ascending order.
  // Node arrays have length + 1 entries and literals has length + 2.
  let cost = Float::reinterpret_from_uint(ref_get(self.info, pos))
  let copy = self.copy_length(pos)
  let insert = (ref_get(self.inserts, pos) & 0x7ffffffU).reinterpret_as_int()
  let distance = ref_get(self.distances, pos)
  let shortcut = if pos == 0 {
    0U
  } else if distance.to_int64() + copy.to_int64() <=
    absolute.to_uint64().reinterpret_as_int64() +
    pos.to_int64() +
    gap.to_int64() &&
    distance.to_int64() <= reach.to_int64() + gap.to_int64() &&
    self.distance_code(pos) > 0 {
    pos.reinterpret_as_uint()
  } else {
    // A command starts at a prior node. An unfilled node steps back by one.
    ref_get(self.info, pos - copy - insert)
  }
  ref_set(self.info, pos, shortcut)
  let literal_cost = ref_get(self.model.literals, pos)
  if cost <= literal_cost {
    // Masked slots fit the eight-entry queue and its four distances per slot.
    let mut slot = (-1 - self.index) & 7
    self.index += 1
    ref_set(self.positions, slot, pos)
    ref_set(self.costs, slot, cost)
    ref_set(self.differences, slot, cost - literal_cost)
    let mut i = 0
    let mut p = shortcut.reinterpret_as_int()
    while i < 4 && p > 0 {
      // Shortcuts select the current or an earlier evaluated node. Its
      // parent is nonnegative for p > 0 and precedes p.
      ref_set(self.cache, 4 * slot + i, ref_get(self.distances, p))
      i += 1
      let parent = p -
        self.copy_length(p) -
        (ref_get(self.inserts, p) & 0x7ffffffU).reinterpret_as_int()
      p = ref_get(self.info, parent).reinterpret_as_int()
    }
    for j in i..<4 {
      // 0 <= j - i < 4, the size of the initial distance cache.
      ref_set(self.cache, 4 * slot + j, ref_get(initial, j - i))
    }
    for _ in 1..<self.index.min(8) {
      let next = (slot + 1) & 7
      if ref_get(self.differences, slot) > ref_get(self.differences, next) {
        let p = ref_get(self.positions, slot)
        ref_set(self.positions, slot, ref_get(self.positions, next))
        ref_set(self.positions, next, p)
        let c = ref_get(self.costs, slot)
        ref_set(self.costs, slot, ref_get(self.costs, next))
        ref_set(self.costs, next, c)
        let d = ref_get(self.differences, slot)
        ref_set(self.differences, slot, ref_get(self.differences, next))
        ref_set(self.differences, next, d)
        for j in 0..<4 {
          let v = ref_get(self.cache, 4 * slot + j)
          ref_set(self.cache, 4 * slot + j, ref_get(self.cache, 4 * next + j))
          ref_set(self.cache, 4 * next + j, v)
        }
      }
      slot = next
    }
  }
}

///|
// Expanding the command helpers slowed q11 on Wasm GC.
#cfg(target="wasm-gc")
const HQ_INLINE_COMMANDS : Bool = false

///|
#cfg(not(target="wasm-gc"))
const HQ_INLINE_COMMANDS : Bool = true

///|
fn HqDp::set(
  self : HqDp,
  pos : Int32,
  start : Int32,
  length : Int32,
  code : Int32,
  distance : Int32,
  short : Int32,
  cost : Float,
) -> Unit {
  let next = pos + length
  self.lengths[next] = (length | ((length + 9 - code) << 25)).reinterpret_as_uint()
  self.distances[next] = distance
  self.inserts[next] = ((short << 27) | (pos - start)).reinterpret_as_uint()
  self.info[next] = cost.reinterpret_as_uint()
}

///|
fn HqDp::update(
  self : HqDp,
  encoder : Encoder,
  data : FixedArray[Byte],
  start : Int32,
  absolute : UInt32,
  pos : Int32,
  length : Int32,
  initial : FixedArray[Int32],
  matches : ArrayView[UInt32],
) -> Int32 {
  let gap = match encoder.dictionary {
    Some(d) => d.length()
    None => 0
  }
  let reach = (absolute.to_uint64() + pos.to_uint64())
    .min(encoder.max_distance.to_uint64())
    .to_int()
  let cur = start + pos
  let max_length = length - pos
  let ring_bits = encoder.window_bits.max(encoder.window_bits.min(18).max(16)) +
    1
  let mask = (1U << ring_bits) - 1U
  let current = absolute + pos.reinterpret_as_uint()
  let masked = current & mask
  self.evaluate(pos, absolute, encoder.max_distance, gap, initial)
  // The queue has eight slots, with evaluated block positions in 0..=pos.
  // Each slot has four cached distances. Literals has length + 2 entries.
  let best = (0 - self.index) & 7
  let start_cost = ref_get(self.costs, best) +
    self.model.minimum +
    (
      ref_get(self.model.literals, pos) -
      ref_get(self.model.literals, ref_get(self.positions, best))
    )
  let mut minimum = 2
  let mut min_cost = start_cost
  let mut next_bucket = 4
  let mut next_offset = 10
  // info has length + 1 nodes, including the guarded terminal node.
  while pos + minimum <= length &&
        Float::reinterpret_from_uint(ref_get(self.info, pos + minimum)) <=
        min_cost {
    minimum += 1
    if minimum == next_offset {
      min_cost += 1.0
      next_offset += next_bucket
      next_bucket *= 2
    }
  }
  let max_zopfli = if self.quality == 10 { 150 } else { 325 }
  let mut result = 0
  for k in 0..<(if self.quality == 10 { 1 } else { 5 }).min(self.index.min(8)) {
    let slot = (k - self.index) & 7
    let command_start = ref_get(self.positions, slot)
    let ic = insert_code(pos - command_start)
    // insert_code returns an index in the 24 insert length codes.
    let base = ref_get(self.differences, slot) +
      Float::from_int(ref_get(insert_length_extra, ic)) +
      ref_get(self.model.literals, pos)
    let mut best_length = minimum - 1
    for j = 0; j < 16 && best_length < max_length; j = j + 1 {
      let index = if j < 4 { j } else if j < 10 { 0 } else { 1 }
      let offset = if j < 4 {
        0
      } else {
        let pair = if j < 10 { j - 4 } else { j - 10 }
        (if (pair & 1) == 0 { -1 } else { 1 }) * (1 + pair / 2)
      }
      // index is 0..3 within the masked slot's four cached distances.
      let backward = ref_get(self.cache, 4 * slot + index) + offset
      if masked.to_uint64() + best_length.to_uint64() > mask.to_uint64() {
        break
      }
      if backward <= 0 ||
        backward.to_int64() > reach.to_int64() + gap.to_int64() {
        continue
      }
      // best_length < max_length and cur + max_length is the block end.
      let continuation = ref_get(data, cur + best_length)
      let mut matched = 0
      if backward <= reach {
        let previous = (current - backward.reinterpret_as_uint()) & mask
        // The retained history covers backward when it is within reach.
        if previous.to_uint64() + best_length.to_uint64() > mask.to_uint64() ||
          continuation != ref_get(data, cur - backward + best_length) {
          continue
        }
        // The retained window covers backward. cur + max_length is the block end.
        matched = ref_match_length(data, cur - backward, cur, max_length)
      } else if encoder.dictionary is Some(dict) {
        let offset = (dict.length().to_int64() +
        reach.to_int64() -
        backward.to_int64()).to_int()
        let limit = (dict.length() - offset).min(max_length)
        if best_length >= limit ||
          continuation != dict.content[offset + best_length] {
          continue
        }
        // limit is at most max_length in the input.
        while matched < limit &&
              dict.content[offset + matched] == ref_get(data, cur + matched) {
          matched += 1
        }
      }
      // The 16 short codes fit the 64 distance costs.
      let dist_cost = base + ref_get(self.model.distances, j)
      for n in (best_length + 1)..<=matched {
        // n is at least 2. Both length codes are below 24, giving one of
        // the nine explicit cells.
        let cc = if !HQ_INLINE_COMMANDS {
          copy_code(n)
        } else if n < COPY_TABLE_SIZE {
          ref_get(copy_code_table, n).to_int()
        } else {
          length_code_above(copy_length_base, n)
        }
        let symbol = if HQ_INLINE_COMMANDS {
          let cell = if j == 0 && ic < 8 && cc < 16 {
            cc >> 3
          } else {
            ref_get(explicit_cells, (ic >> 3) * 3 + (cc >> 3))
          }
          (cell << 6) | ((ic & 7) << 3) | (cc & 7)
        } else {
          command_symbol(ic, cc, j == 0)
        }
        // The code and symbol are in their 24- and 704-entry tables.
        // matched <= max_length bounds pos + n by the last node.
        let next = pos + n
        let cost = (if symbol < 128 { base } else { dist_cost }) +
          Float::from_int(ref_get(copy_length_extra, cc)) +
          ref_get(self.model.commands, symbol)
        if cost < Float::reinterpret_from_uint(ref_get(self.info, next)) {
          if HQ_INLINE_COMMANDS {
            ref_set(self.lengths, next, (n | (9 << 25)).reinterpret_as_uint())
            ref_set(self.distances, next, backward)
            ref_set(
              self.inserts,
              next,
              (((j + 1) << 27) | (pos - command_start)).reinterpret_as_uint(),
            )
            ref_set(self.info, next, cost.reinterpret_as_uint())
          } else {
            self.set(pos, command_start, n, n, backward, j + 1, cost)
          }
          result = result.max(n)
        }
        best_length = n
      }
    }
    if k >= 2 {
      continue
    }
    let mut n = minimum
    for j in 0..<(matches.length() / 2) {
      let distance = matches[2 * j].reinterpret_as_int()
      let packed = matches[2 * j + 1]
      let dictionary = distance.to_int64() > reach.to_int64() + gap.to_int64()
      let symbol = distance_symbol(distance)
      // Matches have distances in 1..=MAX_CODED_DISTANCE, so symbol < 64.
      let dist_cost = base +
        Float::from_int(distance_extra_bits(symbol)) +
        ref_get(self.model.distances, symbol)
      let max_match = (packed >> 5).reinterpret_as_int()
      if n < max_match && (dictionary || max_match > max_zopfli) {
        n = max_match
      }
      while n <= max_match {
        let code = if dictionary && (packed & 31U) != 0U {
          (packed & 31U).reinterpret_as_int()
        } else {
          n
        }
        // code is a nonnegative match or dictionary word length, and the
        // lookup below returns one of 24 length codes.
        let cc = if !HQ_INLINE_COMMANDS {
          copy_code(code)
        } else if code < COPY_TABLE_SIZE {
          ref_get(copy_code_table, code).to_int()
        } else {
          length_code_above(copy_length_base, code)
        }
        let symbol = if HQ_INLINE_COMMANDS {
          // Both length codes are below 24, giving one of nine cells.
          let cell = ref_get(explicit_cells, (ic >> 3) * 3 + (cc >> 3))
          (cell << 6) | ((ic & 7) << 3) | (cc & 7)
        } else {
          command_symbol(ic, cc, false)
        }
        // The code and symbol are in their 24- and 704-entry tables.
        // max_match <= max_length bounds pos + n by the last node.
        let next = pos + n
        let cost = dist_cost +
          Float::from_int(ref_get(copy_length_extra, cc)) +
          ref_get(self.model.commands, symbol)
        if cost < Float::reinterpret_from_uint(ref_get(self.info, next)) {
          if HQ_INLINE_COMMANDS {
            ref_set(
              self.lengths,
              next,
              (n | ((n + 9 - code) << 25)).reinterpret_as_uint(),
            )
            ref_set(self.distances, next, distance)
            ref_set(
              self.inserts,
              next,
              (pos - command_start).reinterpret_as_uint(),
            )
            ref_set(self.info, next, cost.reinterpret_as_uint())
          } else {
            self.set(pos, command_start, n, code, distance, 0, cost)
          }
          result = result.max(n)
        }
        n += 1
      }
    }
  }
  result
}

///|
fn HqDp::backtrack(
  self : HqDp,
  encoder : Encoder,
  absolute : UInt32,
  length : Int32,
) -> Unit {
  let mut end = length
  while (self.inserts[end] & 0x7ffffffU) == 0U && self.lengths[end] == 1U {
    end -= 1
  }
  self.info[end] = 0xffffffffU
  while end != 0 {
    let size = self.copy_length(end) +
      (self.inserts[end] & 0x7ffffffU).reinterpret_as_int()
    end -= size
    self.info[end] = size.reinterpret_as_uint()
  }
  let commands = encoder.ref_commands.unwrap()
  let gap = match encoder.dictionary {
    Some(d) => d.length()
    None => 0
  }
  let mut pos = 0
  let mut step = self.info[0]
  let mut first = true
  while step != 0xffffffffU {
    let next = pos + step.reinterpret_as_int()
    let copy = self.copy_length(next)
    let mut insert = (self.inserts[next] & 0x7ffffffU).reinterpret_as_int()
    pos += insert
    step = self.info[next]
    if first {
      insert += encoder.ref_insert
      encoder.ref_insert = 0
      first = false
    }
    let distance = self.distances[next]
    let code = copy + 9 - (self.lengths[next] >> 25).reinterpret_as_int()
    let reach = (absolute.to_uint64() + pos.to_uint64())
      .min(encoder.max_distance.to_uint64())
      .to_int()
    let dictionary = distance.to_int64() > reach.to_int64() + gap.to_int64()
    let dc = self.distance_code(next)
    commands.push(RefCommand::new(insert, copy, code - copy, dc))
    if !dictionary && dc > 0 {
      for i = 3; i > 0; i = i - 1 {
        encoder.ref_distances[i] = encoder.ref_distances[i - 1]
      }
      encoder.ref_distances[0] = distance
    }
    encoder.ref_literals += insert
    pos += copy
  }
  encoder.ref_insert += length - pos
}
