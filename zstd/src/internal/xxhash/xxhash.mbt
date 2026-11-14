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
#cfg(any(target="native", target="wasm"))
#inline
fn read32(data : FixedArray[Byte], i : Int32) -> UInt64 {
  // digest calls only with at least four valid stripe bytes left.
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint32_le(i).to_uint64()
}

///|
#cfg(not(any(target="native", target="wasm")))
fn read32(data : FixedArray[Byte], i : Int32) -> UInt64 {
  (data[i].to_uint() |
  (data[i + 1].to_uint() << 8) |
  (data[i + 2].to_uint() << 16) |
  (data[i + 3].to_uint() << 24)).to_uint64()
}

///|
#cfg(any(target="native", target="wasm"))
#inline
fn read64(data : FixedArray[Byte], i : Int32) -> UInt64 {
  // consume_stripe has 32 valid bytes, and digest checks n - i >= 8.
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint64_le(i)
}

///|
#cfg(not(any(target="native", target="wasm")))
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
  i = consume_stripes(self.acc, data, i, end)
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

///|
/// Adds the whole stripes of `data[i:end]` to the lanes `acc`, and returns
/// where they end. The lanes stay in locals across the stripes.
#cfg(not(target="js"))
fn consume_stripes(
  acc : FixedArray[UInt64],
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
) -> Int32 {
  let mut i = start
  guard end - i >= 32 else { return i }
  let mut v0 = acc[0]
  let mut v1 = acc[1]
  let mut v2 = acc[2]
  let mut v3 = acc[3]
  while end - i >= 32 {
    v0 = round(v0, read64(data, i))
    v1 = round(v1, read64(data, i + 8))
    v2 = round(v2, read64(data, i + 16))
    v3 = round(v3, read64(data, i + 24))
    i += 32
  }
  acc[0] = v0
  acc[1] = v1
  acc[2] = v2
  acc[3] = v3
  i
}

///|
/// The same on JS, where a 64-bit integer is a BigInt and every operation
/// on one allocates: the lanes are split into 32-bit halves for the loop,
/// `limbs[2k]` the high half of lane k and `limbs[2k + 1]` the low.
#cfg(target="js")
fn consume_stripes(
  acc : FixedArray[UInt64],
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
) -> Int32 {
  let mut i = start
  guard end - i >= 32 else { return i }
  let limbs = FixedArray::make(8, 0U)
  for k in 0..<4 {
    limbs[2 * k] = (acc[k] >> 32).to_uint()
    limbs[2 * k + 1] = acc[k].to_uint()
  }
  while end - i >= 32 {
    round_limbs(limbs, 0, data, i)
    round_limbs(limbs, 2, data, i + 8)
    round_limbs(limbs, 4, data, i + 16)
    round_limbs(limbs, 6, data, i + 24)
    i += 32
  }
  for k in 0..<4 {
    acc[k] = (limbs[2 * k].to_uint64() << 32) | limbs[2 * k + 1].to_uint64()
  }
  i
}

///|
/// `round` on the lane whose halves are `v[at]` (high) and `v[at + 1]`
/// (low), with the eight bytes of `data` from `i`: everything modulo 2^64.
#cfg(target="js")
fn round_limbs(
  v : FixedArray[UInt32],
  at : Int32,
  data : FixedArray[Byte],
  i : Int32,
) -> Unit {
  let lane_lo = read32_u(data, i)
  let lane_hi = read32_u(data, i + 4)
  // lane * PRIME64_2
  let t_lo = lane_lo * 0x27D4EB4FU
  let t_hi = mul_high(lane_lo, 0x27D4EB4FU) +
    lane_hi * 0x27D4EB4FU +
    lane_lo * 0xC2B2AE3DU
  // acc + that
  let s_lo = v[at + 1] + t_lo
  let s_hi = v[at] + t_hi + (if s_lo < t_lo { 1U } else { 0U })
  // rotated left by 31
  let r_hi = (s_hi << 31) | (s_lo >> 1)
  let r_lo = (s_lo << 31) | (s_hi >> 1)
  // times PRIME64_1
  v[at + 1] = r_lo * 0x85EBCA87U
  v[at] = mul_high(r_lo, 0x85EBCA87U) + r_hi * 0x85EBCA87U + r_lo * 0x9E3779B1U
}

///|
/// The high 32 bits of the 64-bit product of `a` and `b`, from 16-bit
/// halves whose products fit in 32 bits.
#cfg(target="js")
fn mul_high(a : UInt32, b : UInt32) -> UInt32 {
  let a0 = a & 0xFFFF
  let a1 = a >> 16
  let b0 = b & 0xFFFF
  let b1 = b >> 16
  let p00 = a0 * b0
  let p01 = a0 * b1
  let p10 = a1 * b0
  let mid = (p00 >> 16) + (p01 & 0xFFFF) + (p10 & 0xFFFF)
  a1 * b1 + (p01 >> 16) + (p10 >> 16) + (mid >> 16)
}

///|
#cfg(target="js")
fn read32_u(data : FixedArray[Byte], i : Int32) -> UInt32 {
  data[i].to_uint() |
  (data[i + 1].to_uint() << 8) |
  (data[i + 2].to_uint() << 16) |
  (data[i + 3].to_uint() << 24)
}
