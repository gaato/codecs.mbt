// google/brotli v1.2.1 compress_fragment{,_two_pass}.c.
// Copyright 2015 Google Inc.; MIT, see LICENSE-encoder.

///|
fn FragmentArena::literal_tree(
  self : FragmentArena,
  w : LowBits,
  data : FixedArray[Byte],
  start : Int32,
  size : Int32,
) -> Int32 {
  let hist = FixedArray::make(256, 0)
  let sampled = size >= 32768
  let step = if sampled { 29 } else { 1 }
  for p = start; p < start + size; p = p + step {
    hist[data[p].to_int()] += 1
  }
  let mut total = (size + step - 1) / step
  for i in 0..<256 {
    let adjust = 2 * hist[i].min(11) + (if sampled { 1 } else { 0 })
    hist[i] += adjust
    total += adjust
  }
  self.literal = w.fast_tree(self.tables, hist, 8)
  let mut cost = 0
  for i in 0..<256 {
    cost += hist[i] * self.literal.depths[i]
  }
  cost * 125 / total
}

///|
fn FragmentArena::merge(
  self : FragmentArena,
  data : FixedArray[Byte],
  start : Int32,
  size : Int32,
) -> Bool {
  let hist = FixedArray::make(256, 0)
  for p = start; p < start + size; p = p + 43 {
    hist[data[p].to_int()] += 1
  }
  let total = (size + 42) / 43
  let mut cost = (ref_log(total) + 0.5) * total.to_double() + 200.0
  for i in 0..<256 {
    cost -= hist[i].to_double() *
      (self.literal.depths[i].to_double() + ref_log(hist[i]))
  }
  cost >= 0.0
}

///|
fn fragment_use_raw(
  meta : Int32,
  emit : Int32,
  insert : Int32,
  ratio : Int32,
) -> Bool {
  (emit - meta) * 50 <= insert && ratio > 980
}

///|
fn FragmentArena::one_pass(
  self : FragmentArena,
  w : LowBits,
  data : FixedArray[Byte],
  size : Int32,
  last : Bool,
) -> Unit {
  let initial = w.pos
  if size > 0 {
    let mut input = 0
    let mut emit = 0
    let mut first = true
    while input < size {
      let meta = input
      let mut block = (size - input).min(98304)
      let mut total = block
      let mlen = w.pos + 3
      w.header(block, false)
      w.write(13, 0)
      let ratio = self.literal_tree(w, data, input, block)
      if first {
        for i in 0..<(self.cache.pos / 8) {
          w.write(8, self.cache.data[i].to_int())
        }
        if (self.cache.pos & 7) != 0 {
          w.write(
            self.cache.pos & 7,
            self.cache.data[self.cache.pos / 8].to_int(),
          )
        }
        first = false
      } else {
        self.command_tree(w, false)
      }
      let mut restarted = false
      for ;; {
        let seed = low_command_seed()
        FixedArray::unsafe_blit(self.histogram, 0, seed, 0, 128)
        let matcher = FragmentMatcher::new(
          data,
          self.table,
          self.bits,
          5,
          input,
          block,
          size - input,
          emit,
        )
        while matcher.next() is Some(m) {
          if !m.consecutive &&
            m.insert >= 6210 &&
            fragment_use_raw(meta, m.literal, m.insert, ratio) {
            let base = m.literal + m.insert
            w.raw(data, meta, base - meta, mlen - 3)
            input = base
            emit = base
            restarted = true
            break
          }
          if m.consecutive {
            self.copy0(w, m.copy, false)
            self.distance0(w, m.distance)
          } else {
            self.insert0(w, m.insert)
            self.literal0(w, data, m.literal, m.insert)
            if m.same {
              self.one_code(w, 64, 0, 0)
            } else {
              self.distance0(w, m.distance)
            }
            self.copy0(w, m.copy, true)
          }
        }
        if restarted {
          break
        }
        emit = matcher.emit
        let end = input + block
        input = end
        let next = (size - input).min(65536)
        if input < size &&
          total + next <= 1048576 &&
          self.merge(data, input, next) {
          total += next
          block = next
          w.patch(20, total - 1, mlen)
          continue
        }
        if emit < end {
          let insert = end - emit
          if insert >= 6210 && fragment_use_raw(meta, emit, insert, ratio) {
            w.raw(data, meta, end - meta, mlen - 3)
          } else {
            self.insert0(w, insert)
            self.literal0(w, data, emit, insert)
          }
        }
        emit = end
        break
      }
    }
    if !last {
      let cache = LowBits::new(512)
      self.command_tree(cache, false)
      self.cache = cache
    }
    if w.pos - initial > 31 + 8 * size {
      w.raw(data, 0, size, initial)
    }
  }
  if last {
    w.write(2, 3)
    w.align()
  }
}

///|
fn FragmentArena::create_program(
  self : FragmentArena,
  data : FixedArray[Byte],
  start : Int32,
  size : Int32,
  remaining : Int32,
) -> Unit {
  self.command_count = 0
  self.literal_count = 0
  let minimum = if self.bits <= 15 { 4 } else { 6 }
  let matcher = FragmentMatcher::new(
    data,
    self.table,
    self.bits,
    minimum,
    start,
    size,
    remaining,
    start,
  )
  while matcher.next() is Some(m) {
    if m.consecutive {
      let (c, e) = fragment_copy(m.copy)
      self.push1(c, e)
      let (c, e) = fragment_distance(m.distance)
      self.push1(c, e)
    } else {
      let (c, e) = fragment_insert(m.insert)
      self.push1(c, e)
      FixedArray::unsafe_blit(
        self.literals,
        self.literal_count,
        data,
        m.literal,
        m.insert,
      )
      self.literal_count += m.insert
      if m.same {
        self.push1(64, 0)
      } else {
        let (c, e) = fragment_distance(m.distance)
        self.push1(c, e)
      }
      let (c, e, again) = fragment_last_copy(m.copy)
      self.push1(c, e)
      if again {
        self.push1(64, 0)
      }
    }
  }
  let insert = start + size - matcher.emit
  if insert > 0 {
    let (c, e) = fragment_insert(insert)
    self.push1(c, e)
    FixedArray::unsafe_blit(
      self.literals,
      self.literal_count,
      data,
      matcher.emit,
      insert,
    )
    self.literal_count += insert
  }
}

///|
fn FragmentArena::should_compress(
  self : FragmentArena,
  data : FixedArray[Byte],
  start : Int32,
  size : Int32,
) -> Bool {
  if self.literal_count.to_double() < 0.98 * size.to_double() {
    return true
  }
  let hist = FixedArray::make(256, 0)
  for p = start; p < start + size; p = p + 43 {
    hist[data[p].to_int()] += 1
  }
  ref_entropy(hist) < size.to_double() * 8.0 * 0.98 / 43.0
}

///|
fn FragmentArena::store_program(self : FragmentArena, w : LowBits) -> Unit {
  let hist = FixedArray::make(256, 0)
  for i in 0..<self.literal_count {
    hist[self.literals[i].to_int()] += 1
  }
  self.literal = w.fast_tree(self.tables, hist, 8)
  self.histogram.fill(0)
  for i in 0..<self.command_count {
    self.histogram[self.commands[i] & 255] += 1
  }
  for c in [1, 2, 64, 84] {
    self.histogram[c] += 1
  }
  self.command_tree(w, true)
  let mut pos = 0
  for i in 0..<self.command_count {
    let cmd = self.commands[i]
    let c = cmd & 255
    let extra = cmd >> 8
    w.write(self.depth[c], self.codes[c])
    w.write(self.extra[c], extra)
    if c < 24 {
      let insert = insert_length_base[c] + extra
      for _ in 0..<insert {
        let b = self.literals[pos].to_int()
        pos += 1
        w.write(self.literal.depths[b], self.literal.bits[b])
      }
    }
  }
}

///|
fn FragmentArena::two_pass(
  self : FragmentArena,
  w : LowBits,
  data : FixedArray[Byte],
  size : Int32,
  last : Bool,
) -> Unit {
  let initial = w.pos
  let mut input = 0
  while input < size {
    let n = (size - input).min(131072)
    self.create_program(data, input, n, size - input)
    if self.should_compress(data, input, n) {
      w.header(n, false)
      w.write(13, 0)
      self.store_program(w)
    } else {
      w.header(n, true)
      w.align()
      w.bytes(data, input, n)
    }
    input += n
  }
  if w.pos - initial > 31 + 8 * size {
    w.raw(data, 0, size, initial)
  }
  if last {
    w.write(2, 3)
    w.align()
  }
}
