// Port of google/brotli v1.2.1 c/enc/hash*.h and quality.h.
// Copyright 2010, 2016, 2025 Google Inc.; MIT, LICENSE-encoder.
// Tagged hashers use scalar tag comparisons with the reference's visit order.

///|
priv struct RefMatch {
  mut length : Int32
  mut distance : Int32
  mut delta : Int32
  mut score : Int32
}

///|
fn RefMatch::new() -> RefMatch {
  { length: 0, distance: 0, delta: 0, score: 2020, }
}

///|
priv struct RefHasher {
  chain : Bool
  long_hash : Bool
  tagged : Bool
  bits : Int32
  block_bits : Int32
  checks : Int32
  hops : Int32
  bank_bits : Int32
  ring_mask : UInt32
  counts : FixedArray[UInt16]
  buckets : FixedArray[UInt32]
  tags : FixedArray[Byte]
  addresses : FixedArray[UInt32]
  heads : FixedArray[UInt16]
  deltas : FixedArray[UInt16]
  next : FixedArray[UInt16]
  free : FixedArray[UInt16]
  tiny : FixedArray[Byte]
  dict_words : FixedArray[UInt16]
  dict_lengths : FixedArray[Byte]
  mut prepared : Bool
  mut dict_lookups : Int64
  mut dict_matches : Int64
}

///|
fn RefHasher::new(quality : Int32, window : Int32, hint : Int64) -> RefHasher {
  let chain = window <= 16
  let long_hash = !chain && window >= 19 && hint >= 1048576L
  let tagged = !chain && quality <= 6
  let bits = if !chain && !long_hash && quality < 7 { 14 } else { 15 }
  let block_bits = quality - 1
  let checks = if quality < 7 { 4 } else if quality < 9 { 10 } else { 16 }
  let banks = if quality == 9 { 512 } else { 1 }
  let bank_bits = if quality == 9 { 9 } else { 16 }
  {
    chain,
    long_hash,
    tagged,
    bits,
    block_bits,
    checks,
    hops: (if quality > 6 { 7 } else { 8 }) << (quality - 4),
    bank_bits,
    ring_mask: (
      1U <<
      (window.max(if quality == 9 { window.min(18).max(16) } else { 16 }) + 1)
    ) -
    1U,
    counts: FixedArray::make(
      if chain {
        0
      } else {
        1 << bits
      },
      if tagged {
        65535
      } else {
        0
      },
    ),
    buckets: FixedArray::make(
      if chain {
        0
      } else {
        1 << (bits + block_bits)
      },
      0U,
    ),
    tags: FixedArray::make(
      if tagged {
        1 << (bits + block_bits)
      } else {
        0
      },
      b'\x00',
    ),
    addresses: FixedArray::make(if chain { 32768 } else { 0 }, 0xccccccccU),
    heads: FixedArray::make(if chain { 32768 } else { 0 }, 0),
    deltas: FixedArray::make(if chain { banks << bank_bits } else { 0 }, 0),
    next: FixedArray::make(if chain { banks << bank_bits } else { 0 }, 0),
    free: FixedArray::make(if chain { banks } else { 0 }, 0),
    tiny: FixedArray::make(if chain { 65536 } else { 0 }, b'\x00'),
    dict_words: ref_dict_words(),
    dict_lengths: ref_dict_lengths(),
    prepared: true,
    dict_lookups: 0L,
    dict_matches: 0L,
  }
}

///|
// HasherReset preserves setup, allocations and dictionary-search statistics.
// Preparation happens before stitching the next block, as in hash.h.
fn RefHasher::reset(self : RefHasher) -> Unit {
  self.prepared = false
}

///|
fn RefHasher::prepare(self : RefHasher) -> Unit {
  if self.prepared {
    return
  }
  if self.chain {
    self.addresses.fill(0xccccccccU)
    self.heads.fill(0)
    self.tiny.fill(b'\x00')
    self.free.fill(0)
  } else {
    self.counts.fill(if self.tagged { 65535 } else { 0 })
  }
  self.prepared = true
}

///|
fn RefHasher::memory_usage(self : RefHasher) -> Int32 {
  2 *
  (
    self.counts.length() +
    self.heads.length() +
    self.deltas.length() +
    self.next.length() +
    self.free.length()
  ) +
  4 * (self.buckets.length() + self.addresses.length()) +
  self.tags.length() +
  self.tiny.length() +
  2 * self.dict_words.length() +
  self.dict_lengths.length()
}

///|
fn ref_load4(data : FixedArray[Byte], pos : Int32) -> UInt32 {
  data[pos].to_uint() |
  (data[pos + 1].to_uint() << 8) |
  (data[pos + 2].to_uint() << 16) |
  (data[pos + 3].to_uint() << 24)
}

///|
fn RefHasher::hash(
  self : RefHasher,
  data : FixedArray[Byte],
  pos : Int32,
) -> Int32 {
  let tag_bits = if self.tagged { 8 } else { 0 }
  if self.long_hash {
    let n = ref_load4(data, pos).to_uint64() | (data[pos + 4].to_uint64() << 32)
    ((n * (0x1fe35a7bd3579bd3UL << 24)) >> (64 - 15 - tag_bits)).to_int()
  } else {
    ((ref_load4(data, pos) * 0x1e35a7bdU) >> (32 - self.bits - tag_bits)).reinterpret_as_int()
  }
}

///|
fn RefHasher::store(
  self : RefHasher,
  data : FixedArray[Byte],
  pos : Int32,
  absolute : UInt32,
) -> Unit {
  let hash = self.hash(data, pos)
  if self.chain {
    let bank = hash & (self.free.length() - 1)
    let slot = self.free[bank].to_int() & ((1 << self.bank_bits) - 1)
    self.free[bank] = (self.free[bank].to_int() + 1).to_uint16()
    let delta = (absolute - self.addresses[hash])
      .to_uint64()
      .min(65535UL)
      .to_int()
    let at = (bank << self.bank_bits) + slot
    self.deltas[at] = delta.to_uint16()
    self.next[at] = self.heads[hash]
    self.heads[hash] = slot.to_uint16()
    self.addresses[hash] = absolute
    self.tiny[(absolute & 65535U).reinterpret_as_int()] = (hash & 255).to_byte()
  } else {
    let key = if self.tagged { hash >> 8 } else { hash }
    let count = self.counts[key].to_int()
    let at = (key << self.block_bits) + (count & ((1 << self.block_bits) - 1))
    self.buckets[at] = absolute
    self.counts[key] = (if self.tagged { count - 1 } else { count + 1 }).to_uint16()
    if self.tagged {
      self.tags[at] = (hash & 255).to_byte()
    }
  }
}

///|
fn ref_prepare_distances(cache : FixedArray[Int32]) -> Unit {
  for i in 0..<6 {
    let delta = if i % 2 == 0 { -(i / 2 + 1) } else { i / 2 + 1 }
    cache[4 + i] = cache[0] + delta
    cache[10 + i] = cache[1] + delta
  }
}

///|
fn ref_score(length : Int32, distance : Int32) -> Int32 {
  1920 + 135 * length - 30 * (31 - distance.clz())
}

///|
fn ref_match_length(
  data : FixedArray[Byte],
  a : Int32,
  b : Int32,
  limit : Int32,
) -> Int32 {
  let mut n = 0
  while n < limit && data[a + n] == data[b + n] {
    n += 1
  }
  n
}

///|
fn RefHasher::static_match(
  self : RefHasher,
  data : FixedArray[Byte],
  pos : Int32,
  limit : Int32,
  reach : Int32,
  result : RefMatch,
) -> Unit {
  if self.dict_matches < self.dict_lookups >> 7 {
    return
  }
  let key = ((ref_load4(data, pos) * 0x1e35a7bdU) >> 18).reinterpret_as_int() <<
    1
  for k in key..<(key + 2) {
    self.dict_lookups += 1L
    let length = self.dict_lengths[k].to_int()
    if length == 0 || length > limit {
      continue
    }
    let word = self.dict_words[k].to_int()
    let offset = dictionary_offsets[length] + length * word
    let mut n = 0
    while n < length && data[pos + n] == dictionary[offset + n] {
      n += 1
    }
    if n == 0 || n + 10 <= length {
      continue
    }
    let cut = length - n
    let transform = (cut << 2) +
      ((0x071b520ada2d3200UL >> (cut * 6)) & 63UL).to_int()
    let distance = reach +
      1 +
      word +
      (transform << dictionary_size_bits[length])
    if distance > MAX_CODED_DISTANCE {
      continue
    }
    let score = ref_score(n, distance)
    if score >= result.score {
      result.length = n
      result.delta = length - n
      result.distance = distance
      result.score = score
      self.dict_matches += 1L
    }
  }
}

///|
fn RefHasher::find(
  self : RefHasher,
  data : FixedArray[Byte],
  pos : Int32,
  absolute : UInt32,
  end : Int32,
  reach : Int32,
  dictionary_reach : Int32,
  cache : FixedArray[Int32],
) -> RefMatch {
  let result = RefMatch::new()
  let hash = self.hash(data, pos)
  let limit = end - pos
  let mut best = 0
  for i in 0..<self.checks {
    let distance = cache[i]
    if distance <= 0 || distance > reach {
      continue
    }
    let prev = pos - distance
    if self.chain &&
      i > 0 &&
      self.tiny[((absolute - distance.reinterpret_as_uint()) & 65535U).reinterpret_as_int()] !=
      (hash & 255).to_byte() {
      continue
    }
    if !self.chain {
      if (absolute & self.ring_mask).ref_match_unsigned() +
        best.ref_match_unsigned() >
        self.ring_mask.ref_match_unsigned() {
        break
      }
      if ((absolute - distance.reinterpret_as_uint()) & self.ring_mask).ref_match_unsigned() +
        best.ref_match_unsigned() >
        self.ring_mask.ref_match_unsigned() ||
        data[pos + best] != data[prev + best] {
        continue
      }
    }
    let n = ref_match_length(data, prev, pos, limit)
    if n >= 3 || (n == 2 && (self.chain || i < 2)) {
      let score = 1920 +
        135 * n +
        15 -
        (if i == 0 { 0 } else { 39 + ((0x1ca10 >> (i & 14)) & 14) })
      if score > result.score {
        result.length = n
        result.distance = distance
        result.score = score
        best = n
      }
    }
  }
  best = best.max(3)
  if self.chain {
    let bank = hash & (self.free.length() - 1)
    let mut backward = (absolute - self.addresses[hash]).ref_match_unsigned()
    let mut slot = self.heads[hash].to_int()
    for _ in 0..<self.hops {
      if backward > reach.ref_match_unsigned() {
        break
      }
      let prev = pos - backward.ref_match_int()
      let at = (bank << self.bank_bits) + slot
      slot = self.next[at].to_int()
      let delta = self.deltas[at].to_int()
      if (absolute & self.ring_mask).ref_match_unsigned() +
        best.ref_match_unsigned() >
        self.ring_mask.ref_match_unsigned() ||
        ((absolute - backward.ref_match_low()) & self.ring_mask).ref_match_unsigned() +
        best.ref_match_unsigned() >
        self.ring_mask.ref_match_unsigned() {
        backward += delta.ref_match_unsigned()
        continue
      }
      if ref_same4(data, pos + best - 3, prev + best - 3) {
        let n = ref_match_length(data, prev, pos, limit)
        if n >= 4 {
          let score = ref_score(n, backward.ref_match_int())
          if score > result.score {
            result.length = n
            result.distance = backward.ref_match_int()
            result.score = score
            best = n
          }
        }
      }
      backward += delta.ref_match_unsigned()
    }
  } else {
    let key = if self.tagged { hash >> 8 } else { hash }
    let count = self.counts[key].to_int()
    let capacity = 1 << self.block_bits
    let available = (if self.tagged { 65535 - count } else { count }).min(
      capacity,
    )
    for i in 0..<available {
      let slot = (if self.tagged { count + 1 + i } else { count - 1 - i }) &
        (capacity - 1)
      let at = (key << self.block_bits) + slot
      if self.tagged && self.tags[at] != (hash & 255).to_byte() {
        continue
      }
      let backward = (absolute - self.buckets[at]).ref_match_unsigned()
      if backward > reach.ref_match_unsigned() {
        break
      }
      let prev = pos - backward.ref_match_int()
      if (absolute & self.ring_mask).ref_match_unsigned() +
        best.ref_match_unsigned() >
        self.ring_mask.ref_match_unsigned() {
        break
      }
      if ((absolute - backward.ref_match_low()) & self.ring_mask).ref_match_unsigned() +
        best.ref_match_unsigned() >
        self.ring_mask.ref_match_unsigned() {
        continue
      }
      if ref_same4(data, pos + best - 3, prev + best - 3) {
        let n = ref_match_length(data, prev, pos, limit)
        if n >= 4 {
          let score = ref_score(n, backward.ref_match_int())
          if score > result.score {
            result.length = n
            result.distance = backward.ref_match_int()
            result.score = score
            best = n
          }
        }
      }
    }
  }
  self.store(data, pos, absolute)
  if result.score == 2020 {
    self.static_match(data, pos, limit, dictionary_reach, result)
  }
  result
}

///|
fn ref_hasher_bound(quality : Int32, window : Int32, hint : Int64) -> Int32 {
  let tables = if window <= 16 {
    if quality == 9 {
      1311744
    } else {
      524290
    }
  } else {
    let bits = if (hint >= 1048576L && window >= 19) || quality >= 7 {
      15
    } else {
      14
    }
    (2 << bits) + ((if quality <= 6 { 5 } else { 4 }) << (bits + quality - 1))
  }
  tables + 98304
}

///|
// These four bytes end at best + 1. The caller checks the reference
// ring limits, best is at least 3, and the input owns its tail padding.
// Native and Wasm use the reference's unaligned word comparison.
#cfg(any(target="native", target="wasm"))
#inline
fn ref_same4(data : FixedArray[Byte], a : Int32, b : Int32) -> Bool {
  let bytes = data.unsafe_reinterpret_as_bytes()
  bytes.unsafe_read_uint32_le(a) == bytes.unsafe_read_uint32_le(b)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn ref_same4(data : FixedArray[Byte], a : Int32, b : Int32) -> Bool {
  data[a] == data[b] &&
  data[a + 1] == data[b + 1] &&
  data[a + 2] == data[b + 2] &&
  data[a + 3] == data[b + 3]
}

///|
// In find, best is at most 256 KiB and ring_mask is below 2^25.
// Ring sums fit UInt32. A chain adds a UInt16 delta only after its
// distance passed the window check, so that addition also cannot wrap.
// Keep the established native/Wasm arithmetic; GC and JS avoid widening.
#cfg(any(target="wasm-gc", target="js"))
#inline
fn UInt32::ref_match_unsigned(self : UInt32) -> UInt32 {
  self
}

///|
#cfg(any(target="wasm-gc", target="js"))
#inline
fn Int32::ref_match_unsigned(self : Int32) -> UInt32 {
  self.reinterpret_as_uint()
}

///|
#cfg(any(target="wasm-gc", target="js"))
#inline
fn UInt32::ref_match_int(self : UInt32) -> Int32 {
  self.reinterpret_as_int()
}

///|
#cfg(any(target="wasm-gc", target="js"))
#inline
fn UInt32::ref_match_low(self : UInt32) -> UInt32 {
  self
}

///|
#cfg(not(any(target="wasm-gc", target="js")))
#inline
fn UInt32::ref_match_unsigned(self : UInt32) -> UInt64 {
  self.to_uint64()
}

///|
#cfg(not(any(target="wasm-gc", target="js")))
#inline
fn Int32::ref_match_unsigned(self : Int32) -> UInt64 {
  self.to_uint64()
}

///|
#cfg(not(any(target="wasm-gc", target="js")))
#inline
fn UInt64::ref_match_int(self : UInt64) -> Int32 {
  self.to_int()
}

///|
#cfg(not(any(target="wasm-gc", target="js")))
#inline
fn UInt64::ref_match_low(self : UInt64) -> UInt32 {
  self.to_uint()
}
