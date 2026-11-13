///|
/// Bit k is set when the tag of slot (head + k) mod 2^row_log of the row at
/// `base` is `tag`: the row's tags compared sixteen at a time, the mask
/// rotated so that the head slot comes first. The caller guarantees
/// 4 <= row_log <= 6, 0 <= head < 2^row_log, and that `base` is a multiple
/// of 2^row_log with base + 2^row_log <= tags.length(). SSE2 lowers
/// eq/bitmask to pcmpeqb/pmovmskb; NEON to vceqq_u8 and a shift/accumulate
/// sequence (moonbit_simd.h).
#cfg(any(target="native", target="wasm"))
pub fn matches(
  tags : FixedArray[Byte],
  base : Int32,
  tag : Byte,
  head : Int32,
  row_log : Int32,
) -> UInt64 {
  let splat = @v128.i8x16_splat(tag)
  let mut equal = 0UL
  for chunk in 0..<(1 << (row_log - 4)) {
    // The row's 2^row_log >= 16 bytes fit the table; so do these sixteen.
    let bits = @v128.i8x16_bitmask(
      @v128.i8x16_eq(@v128.v128_load(tags, base + 16 * chunk), splat),
    )
    equal = equal | (bits.to_uint64() << (16 * chunk))
  }
  rotate(equal, head, 1 << row_log)
}

///|
/// Checked reference on targets without efficient SIMD loads.
#cfg(not(any(target="native", target="wasm")))
pub fn matches(
  tags : FixedArray[Byte],
  base : Int32,
  tag : Byte,
  head : Int32,
  row_log : Int32,
) -> UInt64 {
  let mut equal = 0UL
  for k in 0..<(1 << row_log) {
    if tags[base + k] == tag {
      equal = equal | (1UL << k)
    }
  }
  rotate(equal, head, 1 << row_log)
}

///|
/// Rotates the low `entries` bits of `bits` right by `head`.
fn rotate(bits : UInt64, head : Int32, entries : Int32) -> UInt64 {
  if head == 0 {
    return bits
  }
  let rotated = (bits >> head) | (bits << (entries - head))
  if entries == 64 {
    rotated
  } else {
    rotated & ((1UL << entries) - 1)
  }
}
