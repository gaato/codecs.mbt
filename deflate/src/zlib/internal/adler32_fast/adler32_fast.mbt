///|
/// The modulus of both sums: the largest prime below 2^16.
#cfg(any(target="native", target="wasm"))
const BASE : UInt32 = 65521

///|
/// The most bytes whose sums fit in 32 bits before reducing them (zlib's
/// NMAX), a multiple of 16: 5552 = 347 * 16.
#cfg(any(target="native", target="wasm"))
const NMAX : Int32 = 5552

///|
/// The Adler-32 of the data so far, `adler`, extended by `data`: the same
/// value as `@adler32.update`.
///
/// 16 bytes at a time with SIMD. The encoder keeps the proved
/// `@adler32.update_bytes`: Adler-32 is 2.4% of its time on native.
#cfg(any(target="native", target="wasm"))
pub fn update(adler : UInt32, data : ArrayView[Byte]) -> UInt32 {
  let mut a = adler & 0xFFFF
  let mut b = adler >> 16
  let n = data.length()
  if n == 1 {
    // The view contains exactly one byte.
    a += data.unsafe_get(0).to_uint()
    if a >= BASE {
      a -= BASE
    }
    b += a
    if b >= BASE {
      b -= BASE
      // An unreduced starting b can take the sum just past 2 * BASE.
      if b >= BASE {
        b -= BASE
      }
    }
    return (b << 16) | a
  }
  if n < 16 {
    // zlib's byte loop. For nonempty input, a stays below 2 * BASE.
    for j in 0..<n {
      // j < n == data.length().
      a += data.unsafe_get(j).to_uint()
      b += a
    }
    if n > 0 {
      if a >= BASE {
        a -= BASE
      }
      b %= BASE
    }
    return (b << 16) | a
  }
  let mut i = 0
  while i < n {
    let end = if n - i < NMAX { n } else { i + NMAX }
    let simd_end = end - ((end - i) & 15)
    let bytes = (simd_end - i).reinterpret_as_uint()
    let zero = @v128.i32x4_splat(0)
    let mut s1 = zero
    let mut ps = zero
    let mut s2 = zero
    // Each group adds 16 a + sum((16 - j) x[j]) to b. ps accumulates
    // the preceding groups' sums and s2 accumulates the weighted bytes.
    while i < simd_end {
      // i is a group boundary and i + 16 <= simd_end <= data.length().
      let x = data.unsafe_extract_v128_aligned(i)
      let lo = @v128.i16x8_extend_low_i8x16_u(x)
      let hi = @v128.i16x8_extend_high_i8x16_u(x)
      ps = @v128.i32x4_add(ps, s1)
      s1 = @v128.i32x4_add(
        s1,
        @v128.i32x4_dot_i16x8_s(@v128.i16x8_add(lo, hi), ones),
      )
      s2 = @v128.i32x4_add(
        s2,
        @v128.i32x4_add(
          @v128.i32x4_dot_i16x8_s(lo, weights_lo),
          @v128.i32x4_dot_i16x8_s(hi, weights_hi),
        ),
      )
      i += 16
    }
    b += bytes * a + (lanes_sum(ps) << 4) + lanes_sum(s2)
    a += lanes_sum(s1)
    while i < end {
      a = a + data.unsafe_get(i).to_uint()
      b = b + a
      i += 1
    }
    a = a % BASE
    b = b % BASE
  }
  (b << 16) | a
}

///|
#cfg(any(target="native", target="wasm"))
let weights_lo : V128 = @v128.i16x8_const(16, 15, 14, 13, 12, 11, 10, 9)

///|
#cfg(any(target="native", target="wasm"))
let weights_hi : V128 = @v128.i16x8_const(8, 7, 6, 5, 4, 3, 2, 1)

///|
#cfg(any(target="native", target="wasm"))
let ones : V128 = @v128.i16x8_splat(1)

///|
#cfg(any(target="native", target="wasm"))
/// The four 32-bit lanes of `v`, summed.
fn lanes_sum(v : V128) -> UInt32 {
  @v128.i32x4_extract_lane(v, 0) +
  @v128.i32x4_extract_lane(v, 1) +
  @v128.i32x4_extract_lane(v, 2) +
  @v128.i32x4_extract_lane(v, 3)
}

///|
/// The Adler-32 of the data so far, `adler`, extended by `data`:
/// `@adler32.update` itself, a byte at a time. On JS, where @v128 falls back
/// to code some 300 times slower, unrolling 16 bytes at a time left
/// codec_bench's PNG decode as fast as before (5.62 against 5.61 ms); on
/// Wasm GC, which cannot load 16 bytes at once, unrolling made Adler-32 20%
/// slower, measured on its own (2026-11-13).
#cfg(not(any(target="native", target="wasm")))
pub fn update(adler : UInt32, data : ArrayView[Byte]) -> UInt32 {
  @adler32.update(adler, data)
}
