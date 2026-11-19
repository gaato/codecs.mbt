///|
/// ZSTD_hash4..8 multipliers. The width is selected at construction.
#cfg(any(target="native", target="wasm"))
fn hash_prime(width : Int32) -> UInt64 {
  match width {
    4 => 2654435761UL
    5 => 889523592379UL
    6 => 227718039650203UL
    7 => 58295818150454627UL
    _ => 0xcf1bbcdcb7a56463UL
  }
}

///|
/// Caller guarantees 0 <= p and p + 8 <= the valid data end.
#cfg(any(target="native", target="wasm"))
#inline
fn load64(data : FixedArray[Byte], p : Int32) -> UInt64 {
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint64_le(p)
}

///|
/// Caller guarantees 0 <= p and p + 4 <= the valid data end.
#cfg(any(target="native", target="wasm"))
#inline
fn load32(data : FixedArray[Byte], p : Int32) -> UInt32 {
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint32_le(p)
}

///|
/// Each caller supplies the index's range argument at the access site.
#cfg(any(target="native", target="wasm"))
#inline
fn[T] read(data : FixedArray[T], i : Int32) -> T {
  data.unsafe_get(i)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn[T] read(data : FixedArray[T], i : Int32) -> T {
  data[i]
}

///|
/// Each caller supplies the index's range argument at the access site.
#cfg(any(target="native", target="wasm"))
#inline
fn[T] write(data : FixedArray[T], i : Int32, value : T) -> Unit {
  data.unsafe_set(i, value)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn[T] write(data : FixedArray[T], i : Int32, value : T) -> Unit {
  data[i] = value
}

///|
/// Caller has checked 0 <= q < p <= end <= data.length().
#cfg(any(target="native", target="wasm"))
fn match_length(
  data : FixedArray[Byte],
  p : Int32,
  q : Int32,
  end : Int32,
) -> Int32 {
  @match_length_fast.length(data, p, q, end)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn match_length(
  data : FixedArray[Byte],
  p : Int32,
  q : Int32,
  end : Int32,
) -> Int32 {
  let mut n = 0
  while p + n < end && data[p + n] == data[q + n] {
    n += 1
  }
  n
}

///|
/// The four bytes ending at the current best length must agree before
/// recounting a chain candidate. search stops when best reaches end - p.
#cfg(any(target="native", target="wasm"))
#inline
fn may_beat(
  data : FixedArray[Byte],
  p : Int32,
  q : Int32,
  best : Int32,
) -> Bool {
  // best >= 3, p + best < end, and 0 <= q < p: both reads fit.
  load32(data, q + best - 3) == load32(data, p + best - 3)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn may_beat(
  data : FixedArray[Byte],
  p : Int32,
  q : Int32,
  best : Int32,
) -> Bool {
  let tail = best - 3
  data[q + tail] == data[p + tail] &&
  data[q + tail + 1] == data[p + tail + 1] &&
  data[q + tail + 2] == data[p + tail + 2] &&
  data[q + tail + 3] == data[p + tail + 3]
}

///|
/// ZSTD_hash4 to ZSTD_hash8 of the `width` bytes at `p`, in `log` bits (at
/// most 32), for the targets that read a byte at a time: the word shifted
/// to the top of 64 bits, times the width's prime, its top `log` bits; for
/// width 4 the same in 32 bits. Wasm GC multiplies 64-bit integers natively.
#cfg(target="wasm-gc")
fn hash_bytes(
  data : FixedArray[Byte],
  p : Int32,
  width : Int32,
  log : Int32,
) -> Int32 {
  let mut word = 0UL
  for i in 0..<width {
    word = word | (data[p + i].to_uint64() << (8 * i))
  }
  if width == 4 {
    ((word.to_uint() * 2654435761U) >> (32 - log)).reinterpret_as_int()
  } else {
    let prime = match width {
      5 => 889523592379UL
      6 => 227718039650203UL
      7 => 58295818150454627UL
      _ => 0xcf1bbcdcb7a56463UL
    }
    (((word << (64 - width * 8)) * prime) >> (64 - log)).to_int()
  }
}

///|
/// The same on JS, where a 64-bit integer is a BigInt and every operation
/// on one allocates: the shifted word and the prime in 32-bit halves, and
/// only the high half of their product, which holds the top `log` bits.
#cfg(target="js")
fn hash_bytes(
  data : FixedArray[Byte],
  p : Int32,
  width : Int32,
  log : Int32,
) -> Int32 {
  // The match finders supply 0 <= p and p + width <= the valid data end.
  let word = hash_word(data, p)
  if width == 4 {
    return ((word * 2654435761U) >> (32 - log)).reinterpret_as_int()
  }
  // For widths 5..8 the upper half is the last four bytes. Shifting the
  // first four leaves the other bytes at the top of the lower half.
  let lo = word << (64 - 8 * width)
  let hi = hash_word(data, p + width - 4)
  let prime_hi = match width {
    5 => 0xCFU
    6 => 0xCF1BU
    7 => 0xCF1BBCU
    _ => 0xCF1BBCDCU
  }
  let prime_lo = match width {
    5 => 0x1BBCDCBBU
    6 => 0xBCDCBF9BU
    7 => 0xDCBFA563U
    _ => 0xB7A56463U
  }
  // The high half of the product modulo 2^64.
  let top = mul_high(lo, prime_lo) + hi * prime_lo + lo * prime_hi
  (top >> (32 - log)).reinterpret_as_int()
}

///|
/// Reads four bytes within the hash's valid range.
#cfg(target="js")
#inline
fn hash_word(data : FixedArray[Byte], p : Int32) -> UInt32 {
  data.unsafe_get(p).to_uint() |
  (data.unsafe_get(p + 1).to_uint() << 8) |
  (data.unsafe_get(p + 2).to_uint() << 16) |
  (data.unsafe_get(p + 3).to_uint() << 24)
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
