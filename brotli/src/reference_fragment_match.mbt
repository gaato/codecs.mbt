// google/brotli v1.2.1 compress_fragment{,_two_pass}.c.
// Copyright 2015 Google Inc.; MIT, see LICENSE-encoder.

///|
fn fragment_hash(
  data : FixedArray[Byte],
  pos : Int32,
  bits : Int32,
  length : Int32,
) -> Int32 {
  let mut word = ref_load4(data, pos).to_uint64()
  if length >= 5 {
    word = word | (data[pos + 4].to_uint64() << 32)
  }
  if length >= 6 {
    word = word | (data[pos + 5].to_uint64() << 40)
  }
  (((word << (64 - 8 * length)) * 0x1e35a7bdUL) >> (64 - bits)).to_int()
}

///|
fn fragment_same(
  data : FixedArray[Byte],
  a : Int32,
  b : Int32,
  length : Int32,
) -> Bool {
  ref_same4(data, a, b) &&
  (
    length == 4 ||
    (data[a + 4] == data[b + 4] && (length == 5 || data[a + 5] == data[b + 5]))
  )
}

///|
priv struct FragmentMatch {
  literal : Int32
  insert : Int32
  copy : Int32
  distance : Int32
  same : Bool
  consecutive : Bool
}

///|
priv struct FragmentMatcher {
  data : FixedArray[Byte]
  table : FixedArray[Int32]
  bits : Int32
  minimum : Int32
  end : Int32
  limit : Int32
  mut pos : Int32
  mut emit : Int32
  mut last_distance : Int32
  mut after_match : Bool
  mut first_match : Bool
}

///|
fn FragmentMatcher::new(
  data : FixedArray[Byte],
  table : FixedArray[Int32],
  bits : Int32,
  minimum : Int32,
  start : Int32,
  size : Int32,
  remaining : Int32,
  emit : Int32,
) -> FragmentMatcher {
  {
    data,
    table,
    bits,
    minimum,
    end: start + size,
    limit: if size >= 16 {
      start + (size - minimum).min(remaining - 16)
    } else {
      start
    },
    pos: start + 1,
    emit,
    last_distance: -1,
    after_match: false,
    first_match: false,
  }
}

///|
fn FragmentMatcher::found(
  self : FragmentMatcher,
  candidate : Int32,
  consecutive : Bool,
) -> FragmentMatch {
  let pos = self.pos
  // The table and distance cache point back within data; limit leaves the
  // minimum match inside the fragment and end is within the input.
  let matched = self.minimum +
    ref_match_length(
      self.data,
      candidate + self.minimum,
      pos + self.minimum,
      self.end - pos - self.minimum,
    )
  let distance = pos - candidate
  let result = {
    literal: self.emit,
    insert: pos - self.emit,
    copy: matched,
    distance,
    same: distance == self.last_distance,
    consecutive,
  }
  self.pos += matched
  self.emit = self.pos
  self.last_distance = distance
  self.after_match = true
  self.first_match = !consecutive
  result
}

///|
fn FragmentMatcher::next(self : FragmentMatcher) -> FragmentMatch? {
  if self.pos >= self.limit {
    return None
  }
  if self.after_match {
    let p = self.pos
    if self.minimum == 4 {
      for back in [3, 2, 1] {
        // The first-match path in 1.2.1 hashes p-3 for the p-1 slot.
        let hash_pos = if back == 1 && self.first_match {
          p - 3
        } else {
          p - back
        }
        self.table[fragment_hash(self.data, hash_pos, self.bits, 4)] = p - back
      }
    } else {
      let span = if self.minimum == 5 { 3 } else { 5 }
      for back = span; back > 0; back = back - 1 {
        self.table[fragment_hash(self.data, p - back, self.bits, self.minimum)] = p -
          back
      }
    }
    let key = fragment_hash(self.data, p, self.bits, self.minimum)
    let candidate = self.table[key]
    self.table[key] = p
    self.after_match = false
    if p - candidate <= 262128 &&
      fragment_same(self.data, p, candidate, self.minimum) {
      return Some(self.found(candidate, true))
    }
    self.pos += 1
  }
  let mut next_pos = self.pos
  let mut next_hash = fragment_hash(
    self.data,
    next_pos,
    self.bits,
    self.minimum,
  )
  let mut skip = 32
  for ;; {
    let key = next_hash
    self.pos = next_pos
    next_pos = self.pos + (skip >> 5)
    skip += 1
    if next_pos > self.limit {
      return None
    }
    next_hash = fragment_hash(self.data, next_pos, self.bits, self.minimum)
    let cached = self.pos - self.last_distance
    let candidate = if fragment_same(self.data, self.pos, cached, self.minimum) &&
      cached < self.pos {
      self.table[key] = self.pos
      cached
    } else {
      let at = self.table[key]
      self.table[key] = self.pos
      at
    }
    if fragment_same(self.data, self.pos, candidate, self.minimum) &&
      self.pos - candidate <= 262128 {
      return Some(self.found(candidate, false))
    }
  }
}
