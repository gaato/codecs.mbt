// What stands behind the contracts of bridges.mbt, which `moon prove`
// trusts: each bridge, at every value its precondition allows.

///|
test "shl1_u64 is 2^k for every window exponent" {
  let mut p = 1024UL
  for k in 10..<=41 {
    assert_eq(shl1_u64(k), p)
    p = p * 2
  }
}

///|
test "mantissa_u64 is the mantissa for every mantissa" {
  let mut m = 0UL
  for k in 0..<=7 {
    assert_eq(mantissa_u64(k), m)
    m = m + 1
  }
}
