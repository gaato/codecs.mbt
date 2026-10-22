///|
test "byte_add wraps modulo 256, for every pair of bytes" {
  for a in 0..<256 {
    for b in 0..<256 {
      assert_eq(byte_add(a.to_byte(), b.to_byte()).to_int(), (a + b) % 256)
    }
  }
}

///|
test "byte_of is to_byte, for every byte" {
  for x in 0..<256 {
    assert_eq(byte_of(x).to_int(), x)
  }
}
