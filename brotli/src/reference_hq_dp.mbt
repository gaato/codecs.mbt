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
  let cost = Float::reinterpret_from_uint(self.info[pos])
  let copy = self.copy_length(pos)
  let insert = (self.inserts[pos] & 0x7ffffffU).reinterpret_as_int()
  let distance = self.distances[pos]
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
    self.info[pos - copy - insert]
  }
  self.info[pos] = shortcut
  if cost <= self.model.literals[pos] {
    let mut slot = (-1 - self.index) & 7
    self.index += 1
    self.positions[slot] = pos
    self.costs[slot] = cost
    self.differences[slot] = cost - self.model.literals[pos]
    let mut i = 0
    let mut p = shortcut.reinterpret_as_int()
    while i < 4 && p > 0 {
      self.cache[4 * slot + i] = self.distances[p]
      i += 1
      let parent = p -
        self.copy_length(p) -
        (self.inserts[p] & 0x7ffffffU).reinterpret_as_int()
      p = self.info[parent].reinterpret_as_int()
    }
    for j in i..<4 {
      self.cache[4 * slot + j] = initial[j - i]
    }
    for _ in 1..<self.index.min(8) {
      let next = (slot + 1) & 7
      if self.differences[slot] > self.differences[next] {
        let p = self.positions[slot]
        self.positions[slot] = self.positions[next]
        self.positions[next] = p
        let c = self.costs[slot]
        self.costs[slot] = self.costs[next]
        self.costs[next] = c
        let d = self.differences[slot]
        self.differences[slot] = self.differences[next]
        self.differences[next] = d
        for j in 0..<4 {
          let v = self.cache[4 * slot + j]
          self.cache[4 * slot + j] = self.cache[4 * next + j]
          self.cache[4 * next + j] = v
        }
      }
      slot = next
    }
  }
}

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
  let best = (0 - self.index) & 7
  let start_cost = self.costs[best] +
    self.model.minimum +
    (self.model.literals[pos] - self.model.literals[self.positions[best]])
  let mut minimum = 2
  let mut min_cost = start_cost
  let mut next_bucket = 4
  let mut next_offset = 10
  while pos + minimum <= length &&
        Float::reinterpret_from_uint(self.info[pos + minimum]) <= min_cost {
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
    let command_start = self.positions[slot]
    let ic = insert_code(pos - command_start)
    let base = self.differences[slot] +
      Float::from_int(insert_length_extra[ic]) +
      self.model.literals[pos]
    let mut best_length = minimum - 1
    for j = 0; j < 16 && best_length < max_length; j = j + 1 {
      let index = if j < 4 { j } else if j < 10 { 0 } else { 1 }
      let offset = if j < 4 {
        0
      } else {
        let pair = if j < 10 { j - 4 } else { j - 10 }
        (if (pair & 1) == 0 { -1 } else { 1 }) * (1 + pair / 2)
      }
      let backward = self.cache[4 * slot + index] + offset
      if masked.to_uint64() + best_length.to_uint64() > mask.to_uint64() {
        break
      }
      if backward <= 0 ||
        backward.to_int64() > reach.to_int64() + gap.to_int64() {
        continue
      }
      let continuation = data[cur + best_length]
      let mut matched = 0
      if backward <= reach {
        let previous = (current - backward.reinterpret_as_uint()) & mask
        if previous.to_uint64() + best_length.to_uint64() > mask.to_uint64() ||
          continuation != data[cur - backward + best_length] {
          continue
        }
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
        while matched < limit &&
              dict.content[offset + matched] == data[cur + matched] {
          matched += 1
        }
      }
      let dist_cost = base + self.model.distances[j]
      for n in (best_length + 1)..<=matched {
        let cc = copy_code(n)
        let symbol = command_symbol(ic, cc, j == 0)
        let cost = (if symbol < 128 { base } else { dist_cost }) +
          Float::from_int(copy_length_extra[cc]) +
          self.model.commands[symbol]
        if cost < Float::reinterpret_from_uint(self.info[pos + n]) {
          self.set(pos, command_start, n, n, backward, j + 1, cost)
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
      let dist_cost = base +
        Float::from_int(distance_extra_bits(symbol)) +
        self.model.distances[symbol]
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
        let cc = copy_code(code)
        let symbol = command_symbol(ic, cc, false)
        let cost = dist_cost +
          Float::from_int(copy_length_extra[cc]) +
          self.model.commands[symbol]
        if cost < Float::reinterpret_from_uint(self.info[pos + n]) {
          self.set(pos, command_start, n, code, distance, 0, cost)
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
