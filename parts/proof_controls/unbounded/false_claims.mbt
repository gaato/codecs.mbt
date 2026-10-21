// False claims: each contract fails for some input its precondition allows.

///|
/// `1000 >> 1` is 500.
pub fn half_below_500(
  x : Int32,
) -> Int32 where {
  proof_require: 0 <= x && x <= 1000,
  proof_ensure: result => result <= 499,
} {
  @proof_bits.shr(x, 1)
}

///|
/// `7 & 7` is 7.
pub fn low_bits_below_7(
  x : Int32,
) -> Int32 where {
  proof_require: 0 <= x && x <= 255,
  proof_ensure: result => result < 7,
} {
  @proof_bits.low_bits(x, 3)
}
