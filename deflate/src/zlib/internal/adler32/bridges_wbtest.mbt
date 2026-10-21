///|
test "byte_u32 is to_uint, for every byte" {
  for i in 0..<256 {
    assert_eq(byte_u32(i.to_byte()), i.reinterpret_as_uint())
  }
}
