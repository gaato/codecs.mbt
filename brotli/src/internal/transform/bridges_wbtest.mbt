///|
test "flip is ^, for every byte and the masks Ferment uses" {
  for b in 0..<256 {
    for mask in [32, 5] {
      let x = flip(b.to_byte(), mask.to_byte())
      assert_eq(x, b.to_byte() ^ mask.to_byte())
      assert_true(x.to_int() >= 0 && x.to_int() <= 255)
    }
  }
}
