// Port of google/brotli v1.2.1 c/enc/literal_cost.c, utf8_util.c and
// backward_references_hq.c. Copyright 2013 Google Inc.; MIT, LICENSE-encoder.

///|
const HQ_INFINITY : Float = 1.7e38

///|
fn hq_log(n : Int32) -> Float {
  Float::from_double(ref_log(n))
}

///|
fn hq_mostly_utf8(
  data : FixedArray[Byte],
  start : Int32,
  length : Int32,
) -> Bool {
  let mut valid = 0
  let mut i = 0
  while i < length {
    let b = data[start + i].to_int()
    let mut size = 0
    if b > 0 && b < 128 {
      size = 1
    } else if i + 1 < length &&
      (b & 0xe0) == 0xc0 &&
      (data[start + i + 1].to_int() & 0xc0) == 0x80 {
      let symbol = ((b & 31) << 6) | (data[start + i + 1].to_int() & 63)
      if symbol > 127 {
        size = 2
      }
    } else if i + 2 < length &&
      (b & 0xf0) == 0xe0 &&
      (data[start + i + 1].to_int() & 0xc0) == 0x80 &&
      (data[start + i + 2].to_int() & 0xc0) == 0x80 {
      let symbol = ((b & 15) << 12) |
        ((data[start + i + 1].to_int() & 63) << 6) |
        (data[start + i + 2].to_int() & 63)
      if symbol > 2047 {
        size = 3
      }
    } else if i + 3 < length &&
      (b & 0xf8) == 0xf0 &&
      (data[start + i + 1].to_int() & 0xc0) == 0x80 &&
      (data[start + i + 2].to_int() & 0xc0) == 0x80 &&
      (data[start + i + 3].to_int() & 0xc0) == 0x80 {
      let symbol = ((b & 7) << 18) |
        ((data[start + i + 1].to_int() & 63) << 12) |
        ((data[start + i + 2].to_int() & 63) << 6) |
        (data[start + i + 3].to_int() & 63)
      if symbol > 65535 && symbol <= 0x10ffff {
        size = 4
      }
    }
    if size > 0 {
      valid += size
      i += size
    } else {
      i += 1
    }
  }
  valid.to_double() > 0.75 * length.to_double()
}

///|
fn hq_utf8_position(last : Int32, c : Int32, clamp : Int32) -> Int32 {
  if c < 128 {
    0
  } else if c >= 192 {
    clamp.min(1)
  } else if last < 224 {
    0
  } else {
    clamp.min(2)
  }
}

///|
priv struct HqCost {
  commands : FixedArray[Float]
  distances : FixedArray[Float]
  literals : FixedArray[Float]
  histogram : FixedArray[Int32]
  mut minimum : Float
}

///|
fn HqCost::new(size : Int32) -> HqCost {
  {
    commands: FixedArray::make(704, (0.0 : Float)),
    distances: FixedArray::make(64, (0.0 : Float)),
    literals: FixedArray::make(size + 2, (0.0 : Float)),
    histogram: FixedArray::make(3 * 256, 0),
    minimum: HQ_INFINITY,
  }
}

///|
fn HqCost::initial(
  self : HqCost,
  data : FixedArray[Byte],
  start : Int32,
  length : Int32,
  memory? : HqMemory,
) -> Unit {
  let mark = hq_memory_mark(memory)
  defer hq_memory_restore(memory, mark)
  let hist = self.histogram
  hist.fill(0)
  let utf8 = hq_mostly_utf8(data, start, length)
  let mut clamp = 0
  let window = if utf8 { 495 } else { 2000 }
  let counts = FixedArray::make(3, 0)
  hq_memory_add(memory, 4L * counts.length().to_int64())
  if utf8 {
    let mut previous = 0
    for i in 0..<length {
      let c = data[start + i].to_int()
      counts[hq_utf8_position(previous, c, 2)] += 1
      previous = c
    }
    clamp = if counts[1] + counts[2] < 25 { 0 } else { 1 }
    counts.fill(0)
  }
  let mut context = 0
  let mut previous = 0
  for i in 0..<window.min(length) {
    let c = data[start + i].to_int()
    hist[256 * context + c] += 1
    counts[context] += 1
    context = hq_utf8_position(previous, c, clamp)
    previous = c
  }
  for i in 0..<length {
    if i >= window {
      let c = if i < window + 1 {
        0
      } else {
        data[start + i - window - 1].to_int()
      }
      let last = if i < window + 2 {
        0
      } else {
        data[start + i - window - 2].to_int()
      }
      let context = if utf8 { hq_utf8_position(last, c, clamp) } else { 0 }
      hist[256 * context + data[start + i - window].to_int()] -= 1
      counts[context] -= 1
    }
    if i + window < length {
      let context = if utf8 {
        hq_utf8_position(
          data[start + i + window - 2].to_int(),
          data[start + i + window - 1].to_int(),
          clamp,
        )
      } else {
        0
      }
      hist[256 * context + data[start + i + window].to_int()] += 1
      counts[context] += 1
    }
    let c = if i < 1 { 0 } else { data[start + i - 1].to_int() }
    let last = if i < 2 { 0 } else { data[start + i - 2].to_int() }
    let context = if utf8 { hq_utf8_position(last, c, clamp) } else { 0 }
    let count = hist[256 * context + data[start + i].to_int()].max(1)
    let mut cost = ref_log(counts[context]) - ref_log(count)
    cost += if utf8 { 0.02905 } else { 0.029 }
    if cost < 1.0 {
      cost = cost * 0.5 + 0.5
    }
    if utf8 && i < 2000 {
      cost += 0.35 + 0.35 / 2000.0 * i.to_double()
    }
    self.literals[i + 1] = Float::from_double(cost)
  }
  self.cumulative(length)
  for i in 0..<704 {
    self.commands[i] = hq_log(11 + i)
  }
  for i in 0..<64 {
    self.distances[i] = hq_log(20 + i)
  }
  self.minimum = hq_log(11)
}

///|
fn HqCost::cumulative(self : HqCost, length : Int32) -> Unit {
  let mut carry : Float = 0.0
  self.literals[0] = 0.0
  for i in 0..<length {
    carry += self.literals[i + 1]
    self.literals[i + 1] = self.literals[i] + carry
    carry -= self.literals[i + 1] - self.literals[i]
  }
}

///|
fn hq_set_cost(
  hist : FixedArray[Int32],
  cost : FixedArray[Float],
  literal : Bool,
) -> Unit {
  let sum = hist.fold(init=0, (a, b) => a + b)
  let log_sum = hq_log(sum)
  let mut missing = sum
  if !literal {
    for n in hist {
      if n == 0 {
        missing += 1
      }
    }
  }
  let missing_cost = hq_log(missing) + (2.0 : Float)
  for i in 0..<hist.length() {
    cost[i] = if hist[i] == 0 {
      missing_cost
    } else {
      (log_sum - hq_log(hist[i])).max(1.0)
    }
  }
}

///|
fn HqCost::from_commands(
  self : HqCost,
  data : FixedArray[Byte],
  start : Int32,
  length : Int32,
  commands : Array[RefCommand],
  first : Int32,
  last_insert : Int32,
  memory? : HqMemory,
) -> Unit {
  let mark = hq_memory_mark(memory)
  defer hq_memory_restore(memory, mark)
  self.histogram.fill(0)
  let ch = FixedArray::make(704, 0)
  let dh = FixedArray::make(64, 0)
  let lc = FixedArray::make(256, (0.0 : Float))
  let mut pos = start - last_insert
  for i in first..<commands.length() {
    let command = commands[i]
    ch[command.symbol] += 1
    if command.symbol >= 128 {
      dh[command.distance] += 1
    }
    for j in 0..<command.insert {
      self.histogram[data[pos + j].to_int()] += 1
    }
    pos += command.insert + command.copy
  }
  let lh = FixedArray::makei(256, i => self.histogram[i])
  let bytes = 4L *
    (ch.length() + dh.length() + lc.length() + lh.length()).to_int64()
  hq_memory_add(memory, bytes)
  if memory is Some(m) {
    m.peak.second_model = m.peak.second_model.max(bytes)
  }
  hq_set_cost(lh, lc, true)
  hq_set_cost(ch, self.commands, false)
  hq_set_cost(dh, self.distances, false)
  self.minimum = self.commands.fold(init=HQ_INFINITY, (a, b) => a.min(b))
  for i in 0..<length {
    self.literals[i + 1] = lc[data[start + i].to_int()]
  }
  self.cumulative(length)
}
