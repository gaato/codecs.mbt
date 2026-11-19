// The original XXH32 update paths keep whole-input encoding fast on JS.

///|
fn rotl32(x : UInt32, n : Int32) -> UInt32 {
  (x << n) | (x >> (32 - n))
}

///|
fn xxh_round(acc : UInt32, lane : UInt32) -> UInt32 {
  rotl32(acc + lane * PRIME32_2, 13) * PRIME32_1
}

///|
fn le32(data : FixedArray[Byte], i : Int32) -> UInt32 {
  data[i].to_uint() |
  (data[i + 1].to_uint() << 8) |
  (data[i + 2].to_uint() << 16) |
  (data[i + 3].to_uint() << 24)
}

///|
/// Adds `data[start:start + len]` to the digest.
fn Xxh32::update(
  self : Xxh32,
  data : FixedArray[Byte],
  start : Int32,
  len : Int32,
) -> Unit {
  self.total += len.to_uint64()
  let mut i = start
  let end = start + len
  if self.stripe_len > 0 {
    let n = (16 - self.stripe_len).min(len)
    FixedArray::unsafe_blit(self.stripe, self.stripe_len, data, i, n)
    self.stripe_len += n
    i += n
    if self.stripe_len < 16 {
      return
    }
    let acc = self.acc
    acc[0] = xxh_round(acc[0], le32(self.stripe, 0))
    acc[1] = xxh_round(acc[1], le32(self.stripe, 4))
    acc[2] = xxh_round(acc[2], le32(self.stripe, 8))
    acc[3] = xxh_round(acc[3], le32(self.stripe, 12))
    self.stripe_len = 0
  }
  if end - i >= 16 {
    let acc = self.acc
    let mut v0 = acc[0]
    let mut v1 = acc[1]
    let mut v2 = acc[2]
    let mut v3 = acc[3]
    while end - i >= 16 {
      v0 = xxh_round(v0, le32(data, i))
      v1 = xxh_round(v1, le32(data, i + 4))
      v2 = xxh_round(v2, le32(data, i + 8))
      v3 = xxh_round(v3, le32(data, i + 12))
      i += 16
    }
    acc[0] = v0
    acc[1] = v1
    acc[2] = v2
    acc[3] = v3
  }
  FixedArray::unsafe_blit(self.stripe, 0, data, i, end - i)
  self.stripe_len = end - i
}

///|
/// Adds `data` to the digest.
fn Xxh32::update_view(self : Xxh32, data : BytesView) -> Unit {
  guard data.length() > 0 else { return }
  self.total += data.length().to_uint64()
  // Whole stripes straight from the view; the rest through the stripe.
  let mut i = 0
  if self.stripe_len > 0 {
    let n = (16 - self.stripe_len).min(data.length())
    self.stripe.blit_from_bytesview(self.stripe_len, data[0:n])
    self.stripe_len += n
    i = n
    if self.stripe_len < 16 {
      return
    }
    let acc = self.acc
    acc[0] = xxh_round(acc[0], le32(self.stripe, 0))
    acc[1] = xxh_round(acc[1], le32(self.stripe, 4))
    acc[2] = xxh_round(acc[2], le32(self.stripe, 8))
    acc[3] = xxh_round(acc[3], le32(self.stripe, 12))
    self.stripe_len = 0
  }
  let n = data.length()
  if n - i >= 16 {
    let acc = self.acc
    let mut v0 = acc[0]
    let mut v1 = acc[1]
    let mut v2 = acc[2]
    let mut v3 = acc[3]
    while n - i >= 16 {
      v0 = xxh_round(
        v0,
        data.unsafe_get(i).to_uint() |
        (data.unsafe_get(i + 1).to_uint() << 8) |
        (data.unsafe_get(i + 2).to_uint() << 16) |
        (data.unsafe_get(i + 3).to_uint() << 24),
      )
      v1 = xxh_round(
        v1,
        data.unsafe_get(i + 4).to_uint() |
        (data.unsafe_get(i + 5).to_uint() << 8) |
        (data.unsafe_get(i + 6).to_uint() << 16) |
        (data.unsafe_get(i + 7).to_uint() << 24),
      )
      v2 = xxh_round(
        v2,
        data.unsafe_get(i + 8).to_uint() |
        (data.unsafe_get(i + 9).to_uint() << 8) |
        (data.unsafe_get(i + 10).to_uint() << 16) |
        (data.unsafe_get(i + 11).to_uint() << 24),
      )
      v3 = xxh_round(
        v3,
        data.unsafe_get(i + 12).to_uint() |
        (data.unsafe_get(i + 13).to_uint() << 8) |
        (data.unsafe_get(i + 14).to_uint() << 16) |
        (data.unsafe_get(i + 15).to_uint() << 24),
      )
      i += 16
    }
    acc[0] = v0
    acc[1] = v1
    acc[2] = v2
    acc[3] = v3
  }
  self.stripe.blit_from_bytesview(0, data[i:n])
  self.stripe_len = n - i
}

///|
/// The digest of everything added since the last `reset`. The digest stays
/// open: more bytes may follow.
fn Xxh32::digest(self : Xxh32) -> UInt32 {
  let acc = self.acc
  let mut h = if self.total >= 16 {
    rotl32(acc[0], 1) +
    rotl32(acc[1], 7) +
    rotl32(acc[2], 12) +
    rotl32(acc[3], 18)
  } else {
    PRIME32_5
  }
  h += self.total.to_uint()
  let tail = self.stripe
  let n = self.stripe_len
  let mut i = 0
  while n - i >= 4 {
    h = rotl32(h + le32(tail, i) * PRIME32_3, 17) * PRIME32_4
    i += 4
  }
  while i < n {
    h = rotl32(h + tail[i].to_uint() * PRIME32_5, 11) * PRIME32_1
    i += 1
  }
  h = h ^ (h >> 15)
  h = h * PRIME32_2
  h = h ^ (h >> 13)
  h = h * PRIME32_3
  h ^ (h >> 16)
}
