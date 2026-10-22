///|
test "row_size: every pixel size, widths across the range, against 64-bit arithmetic" {
  let widths = [
    1, 2, 3, 7, 8, 9, 100, 1_000_000, 1_000_001, 0x3FFFFFFF, 0x7FFFFFFE, 0x7FFFFFFF,
  ]
  let limits = [0, 1, 7, 8_000_000, 1_000_000_000, 0x7FFFFFFF]
  for bits in [1, 2, 4, 8, 16, 24, 32, 48, 64] {
    for width in widths {
      for limit in limits {
        let needed = (width.to_int64() * bits.to_int64() + 7L) / 8L
        let expected = if needed <= limit.to_int64() {
          needed.to_int()
        } else {
          -1
        }
        assert_eq(@sizes.row_size(width, bits, limit), expected)
      }
    }
  }
}

///|
test "frame_inside: the sums in 64 bits, where 32-bit ones would wrap" {
  let max = 0xFFFFFFFFL
  assert_true(@sizes.frame_inside(10, 8, 10, 8, 0, 0))
  assert_true(@sizes.frame_inside(10, 8, 3, 2, 7, 6))
  assert_false(@sizes.frame_inside(10, 8, 4, 2, 7, 0))
  assert_false(@sizes.frame_inside(10, 8, 1, 3, 0, 6))
  // x + width is 2^32 + 1: wrapped, it would be 1.
  assert_false(@sizes.frame_inside(10, 8, max, 1, 2, 0))
  assert_false(@sizes.frame_inside(10, 8, 1, max, 0, 2))
  assert_true(@sizes.frame_inside(max, max, max, max, 0, 0))
}
