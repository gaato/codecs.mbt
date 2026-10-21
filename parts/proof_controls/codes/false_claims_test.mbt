///|
test "the Kraft claim is false at run time" {
  // Three codes of one bit over-subscribe the code space: Kraft's sum is
  // 3 * 2^14, yet the check says complete.
  let c = FixedArray::make(16, 0)
  c[1] = 3
  assert_true(@codes.complete_or_over(c))
}
