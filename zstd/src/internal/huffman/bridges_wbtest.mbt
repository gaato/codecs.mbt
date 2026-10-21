///|
test "byte_of is to_byte, for every byte" {
  for x in 0..<256 {
    assert_eq(byte_of(x), x.to_byte())
    assert_eq(byte_of(x).to_int(), x)
  }
}
