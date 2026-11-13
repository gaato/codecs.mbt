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
  let mut i = 0
  while i < n {
    let end = if n - i < NMAX { n } else { i + NMAX }
    let (a1, b1) = sixteens(data, i, (end - i) / 16, a, b)
    a = a1
    b = b1
    i += (end - i) / 16 * 16
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
/// `a` and `b` extended by the `count` 16-byte groups of `data` from `start`
/// (`count * 16 <= NMAX`), unreduced.
///
/// Each group adds `16 a + sum((16 - j) x[j])` to `b` and `sum(x[j])` to `a`.
/// Within the block, `s1` holds the bytes summed so far, `ps` the sum of `s1`
/// before each group (each such byte counts 16 more times in `b` a group)
/// and `s2` the weighted sums; the lanes are summed once. The operations are
/// those that moonbit_simd.h lowers to the fewest instructions: widening (one
/// on SSE2 and NEON), then `i32x4_dot_i16x8_s` (one `pmaddwd` on SSE2, three
/// on NEON); the products are at most 16 * 255, so the signed dot product
/// cannot overflow. u32 arithmetic wraps,
/// and the true `b` of a block is below 2^32 (NMAX), so the result is exact.
///
/// 590,208 bytes on an i5-10400F, 2026-11-13: 51 us against 296 us a byte at
/// a time on native, 50 us against 658 us on Wasm, measured on their own;
/// codec_bench's PNG decode went from 2.34 to
/// 2.06 ms on native and from 3.62 to 3.12 ms on Wasm.
#cfg(any(target="native", target="wasm"))
fn sixteens(
  data : ArrayView[Byte],
  start : Int32,
  count : Int32,
  a : UInt32,
  b : UInt32,
) -> (UInt32, UInt32) {
  if count == 0 {
    return (a, b)
  }
  let zero = @v128.i32x4_splat(0)
  let mut s1 = zero
  let mut ps = zero
  let mut s2 = zero
  for k in 0..<count {
    // SAFETY: start + 16 count <= data.length(), as `update` computes them.
    let x = data.unsafe_extract_v128_aligned(start + k * 16)
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
  }
  (
    a + lanes_sum(s1),
    b +
    count.reinterpret_as_uint() * 16 * a +
    (lanes_sum(ps) << 4) +
    lanes_sum(s2),
  )
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
