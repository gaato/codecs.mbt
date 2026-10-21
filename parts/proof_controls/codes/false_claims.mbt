// False claims: each contract fails for some input its precondition allows.

///|
/// A Kraft check that takes an over-subscribed code for a complete one: it
/// says "complete" when the code space is used up or overdrawn.
pub fn complete_or_over(
  c : FixedArray[Int32],
) -> Bool where {
  proof_require: c.length() == 16,
  proof_ensure: result => !result || @proof_codes.kraft(c) == 32768,
} {
  let mut left = 1
  for l = 1; l < 16; {
    @proof_codes.space_left_step(c, l - 1)
    left = 2 * left - c[l]
    continue l + 1
  } where {
    proof_invariant: 1 <= l && l <= 16,
    proof_invariant: left == @proof_codes.space_left(c, l - 1),
  }
  @proof_codes.kraft_space(c)
  left <= 0
}

///|
/// The first entry of an array is not counted among the entries up to it.
pub fn first_not_counted(
  a : FixedArray[Int32],
) -> Unit where {
  proof_require: a.length() >= 1,
  proof_ensure: @proof_codes.numof(a, a[0], 0, 1) == 0,
} {

}
