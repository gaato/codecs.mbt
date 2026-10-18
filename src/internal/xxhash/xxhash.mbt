// XXH64 with seed 0, fed incrementally, after the xxHash specification
// (https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md).

///|
const PRIME64_1 : UInt64 = 0x9E3779B185EBCA87

///|
const PRIME64_2 : UInt64 = 0xC2B2AE3D27D4EB4F

///|
const PRIME64_3 : UInt64 = 0x165667B19E3779F9

///|
const PRIME64_4 : UInt64 = 0x85EBCA77C2B2AE63

///|
const PRIME64_5 : UInt64 = 0x27D4EB2F165667C5

///|
/// An XXH64 digest in progress: four lane accumulators, the bytes of an
/// unfinished 32-byte stripe, and the length so far.
pub struct Xxh64 {
  priv acc : FixedArray[UInt64]
  priv stripe : FixedArray[Byte]
  priv mut stripe_len : Int32
  priv mut total : UInt64
}

///|
pub fn Xxh64::Xxh64() -> Xxh64 {
  let h = {
    acc: FixedArray::make(4, 0),
    stripe: FixedArray::make(32, 0),
    stripe_len: 0,
    total: 0,
  }
  h.reset()
  h
}

///|
/// Starts a new digest.
pub fn Xxh64::reset(self : Xxh64) -> Unit {
  self.acc[0] = PRIME64_1 + PRIME64_2
  self.acc[1] = PRIME64_2
  self.acc[2] = 0
  self.acc[3] = 0UL - PRIME64_1
  self.stripe_len = 0
  self.total = 0
}

///|
fn rotl(x : UInt64, n : Int32) -> UInt64 {
  (x << n) | (x >> (64 - n))
}

///|
fn round(acc : UInt64, lane : UInt64) -> UInt64 {
  rotl(acc + lane * PRIME64_2, 31) * PRIME64_1
}

///|
fn merge(acc : UInt64, lane_acc : UInt64) -> UInt64 {
  (acc ^ round(0, lane_acc)) * PRIME64_1 + PRIME64_4
}

///|
fn read32(data : FixedArray[Byte], i : Int32) -> UInt64 {
  (data[i].to_uint() |
  (data[i + 1].to_uint() << 8) |
  (data[i + 2].to_uint() << 16) |
  (data[i + 3].to_uint() << 24)).to_uint64()
}

///|
fn read64(data : FixedArray[Byte], i : Int32) -> UInt64 {
  read32(data, i) | (read32(data, i + 4) << 32)
}

///|
fn Xxh64::consume_stripe(
  self : Xxh64,
  data : FixedArray[Byte],
  i : Int32,
) -> Unit {
  let acc = self.acc
  acc[0] = round(acc[0], read64(data, i))
  acc[1] = round(acc[1], read64(data, i + 8))
  acc[2] = round(acc[2], read64(data, i + 16))
  acc[3] = round(acc[3], read64(data, i + 24))
}

///|
/// Adds `data[start:start + len]` to the digest.
pub fn Xxh64::update(
  self : Xxh64,
  data : FixedArray[Byte],
  start : Int32,
  len : Int32,
) -> Unit {
  self.total += len.to_uint64()
  let mut i = start
  let end = start + len
  if self.stripe_len > 0 {
    let n = (32 - self.stripe_len).min(len)
    FixedArray::unsafe_blit(self.stripe, self.stripe_len, data, i, n)
    self.stripe_len += n
    i += n
    if self.stripe_len < 32 {
      return
    }
    self.consume_stripe(self.stripe, 0)
    self.stripe_len = 0
  }
  while end - i >= 32 {
    self.consume_stripe(data, i)
    i += 32
  }
  FixedArray::unsafe_blit(self.stripe, 0, data, i, end - i)
  self.stripe_len = end - i
}

///|
/// Adds `data` to the digest.
pub fn Xxh64::update_bytes(self : Xxh64, data : BytesView) -> Unit {
  self.update(data.to_fixedarray(), 0, data.length())
}

///|
/// The digest of everything added since the last `reset`. The digest stays
/// open: more bytes may follow.
pub fn Xxh64::digest(self : Xxh64) -> UInt64 {
  let acc = self.acc
  let mut h = if self.total >= 32 {
    let mut h = rotl(acc[0], 1) +
      rotl(acc[1], 7) +
      rotl(acc[2], 12) +
      rotl(acc[3], 18)
    for i in 0..<4 {
      h = merge(h, acc[i])
    }
    h
  } else {
    PRIME64_5
  }
  h += self.total
  let tail = self.stripe
  let mut i = 0
  let n = self.stripe_len
  while n - i >= 8 {
    h = rotl(h ^ round(0, read64(tail, i)), 27) * PRIME64_1 + PRIME64_4
    i += 8
  }
  if n - i >= 4 {
    h = rotl(h ^ (read32(tail, i) * PRIME64_1), 23) * PRIME64_2 + PRIME64_3
    i += 4
  }
  while i < n {
    h = rotl(h ^ (tail[i].to_uint64() * PRIME64_5), 11) * PRIME64_1
    i += 1
  }
  h = h ^ (h >> 33)
  h = h * PRIME64_2
  h = h ^ (h >> 29)
  h = h * PRIME64_3
  h ^ (h >> 32)
}
