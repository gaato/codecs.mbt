///|
test "the claims are false at run time" {
  assert_eq(@unbounded.half_below_500(1000), 500)
  assert_eq(@unbounded.low_bits_below_7(7), 7)
}
