///|
#cfg(any(target="native", target="wasm"))
const XXH32_WORD_LOADS : Bool = true

///|
#cfg(target="wasm-gc")
const XXH32_WORD_LOADS : Bool = false

///|
/// Adds `data[start:start + len]` to the digest.
fn Xxh32::update(
  self : Xxh32,
  data : FixedArray[Byte],
  start : Int32,
  len : Int32,
) -> Unit {
  self.update_view(data.unsafe_reinterpret_as_bytes()[start:start + len])
}

///|
/// Adds `data` to the digest.
fn Xxh32::update_view(self : Xxh32, data : BytesView) -> Unit {
  let n = data.length()
  guard n > 0 else { return }
  self.total += n.to_uint64()
  let stripe = self.stripe
  let acc = self.acc
  let stripe_len = self.stripe_len
  let mut i = 0
  if stripe_len > 0 {
    let take = (16 - stripe_len).min(n)
    // take fits both the input and the unfilled part of the stripe.
    for k in 0..<take {
      stripe.unsafe_set(stripe_len + k, data.unsafe_get(k))
    }
    self.stripe_len += take
    i = take
    if self.stripe_len < 16 {
      return
    }
    // The stripe holds 16 initialized bytes, four per lane.
    let stripe_bytes = stripe.unsafe_reinterpret_as_bytes()
    let lane0 = acc[0] + stripe_bytes.unsafe_read_uint32_le(0) * PRIME32_2
    acc[0] = ((lane0 << 13) | (lane0 >> 19)) * PRIME32_1
    let lane1 = acc[1] + stripe_bytes.unsafe_read_uint32_le(4) * PRIME32_2
    acc[1] = ((lane1 << 13) | (lane1 >> 19)) * PRIME32_1
    let lane2 = acc[2] + stripe_bytes.unsafe_read_uint32_le(8) * PRIME32_2
    acc[2] = ((lane2 << 13) | (lane2 >> 19)) * PRIME32_1
    let lane3 = acc[3] + stripe_bytes.unsafe_read_uint32_le(12) * PRIME32_2
    acc[3] = ((lane3 << 13) | (lane3 >> 19)) * PRIME32_1
  }
  if n - i >= 16 {
    let bytes = data.data()
    let base = data.start_offset()
    let mut v0 = acc[0]
    let mut v1 = acc[1]
    let mut v2 = acc[2]
    let mut v3 = acc[3]
    while n - i >= 16 {
      // The loop guard bounds all four words within this view.
      let at = base + i
      let word0 = if XXH32_WORD_LOADS {
        bytes.unsafe_read_uint32_le(at)
      } else {
        bytes.unsafe_get(at).to_uint() |
        (bytes.unsafe_get(at + 1).to_uint() << 8) |
        (bytes.unsafe_get(at + 2).to_uint() << 16) |
        (bytes.unsafe_get(at + 3).to_uint() << 24)
      }
      let lane0 = v0 + word0 * PRIME32_2
      v0 = ((lane0 << 13) | (lane0 >> 19)) * PRIME32_1
      let word1 = if XXH32_WORD_LOADS {
        bytes.unsafe_read_uint32_le(at + 4)
      } else {
        bytes.unsafe_get(at + 4).to_uint() |
        (bytes.unsafe_get(at + 5).to_uint() << 8) |
        (bytes.unsafe_get(at + 6).to_uint() << 16) |
        (bytes.unsafe_get(at + 7).to_uint() << 24)
      }
      let lane1 = v1 + word1 * PRIME32_2
      v1 = ((lane1 << 13) | (lane1 >> 19)) * PRIME32_1
      let word2 = if XXH32_WORD_LOADS {
        bytes.unsafe_read_uint32_le(at + 8)
      } else {
        bytes.unsafe_get(at + 8).to_uint() |
        (bytes.unsafe_get(at + 9).to_uint() << 8) |
        (bytes.unsafe_get(at + 10).to_uint() << 16) |
        (bytes.unsafe_get(at + 11).to_uint() << 24)
      }
      let lane2 = v2 + word2 * PRIME32_2
      v2 = ((lane2 << 13) | (lane2 >> 19)) * PRIME32_1
      let word3 = if XXH32_WORD_LOADS {
        bytes.unsafe_read_uint32_le(at + 12)
      } else {
        bytes.unsafe_get(at + 12).to_uint() |
        (bytes.unsafe_get(at + 13).to_uint() << 8) |
        (bytes.unsafe_get(at + 14).to_uint() << 16) |
        (bytes.unsafe_get(at + 15).to_uint() << 24)
      }
      let lane3 = v3 + word3 * PRIME32_2
      v3 = ((lane3 << 13) | (lane3 >> 19)) * PRIME32_1
      i += 16
    }
    acc[0] = v0
    acc[1] = v1
    acc[2] = v2
    acc[3] = v3
  }
  // The remaining input has fewer than 16 bytes and fits in the stripe.
  for k in 0..<(n - i) {
    stripe.unsafe_set(k, data.unsafe_get(i + k))
  }
  self.stripe_len = n - i
}

///|
/// The digest of everything added since the last `reset`. The digest stays
/// open: more bytes may follow.
fn Xxh32::digest(self : Xxh32) -> UInt32 {
  let acc = self.acc
  let mut h = if self.total >= 16 {
    let a = acc[0]
    let b = acc[1]
    let c = acc[2]
    let d = acc[3]
    ((a << 1) | (a >> 31)) +
    ((b << 7) | (b >> 25)) +
    ((c << 12) | (c >> 20)) +
    ((d << 18) | (d >> 14))
  } else {
    PRIME32_5
  }
  h += self.total.to_uint()
  let tail = self.stripe
  let tail_bytes = tail.unsafe_reinterpret_as_bytes()
  let n = self.stripe_len
  let mut i = 0
  while n - i >= 4 {
    // Four initialized bytes remain in the tail.
    let x = h + tail_bytes.unsafe_read_uint32_le(i) * PRIME32_3
    h = ((x << 17) | (x >> 15)) * PRIME32_4
    i += 4
  }
  while i < n {
    let x = h + tail[i].to_uint() * PRIME32_5
    h = ((x << 11) | (x >> 21)) * PRIME32_1
    i += 1
  }
  h = h ^ (h >> 15)
  h = h * PRIME32_2
  h = h ^ (h >> 13)
  h = h * PRIME32_3
  h ^ (h >> 16)
}
