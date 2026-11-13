///|
test "SIMD equals checked bytes at every alignment mismatch and valid end" {
  for alignment in 0..<16 {
    for len in 0..<=65 {
      let p = 96 + alignment
      let end = p + len
      let data = FixedArray::makei(end, i => (i % 7).to_byte())
      let q = p - 70
      assert_eq(@match_length_fast.length(data, p, q, end), len)
      for mismatch in 0..<len {
        let old = data[p + mismatch]
        data[p + mismatch] = old ^ b'\xff'
        let mut expected = 0
        while p + expected < end && data[p + expected] == data[q + expected] {
          expected += 1
        }
        assert_eq(@match_length_fast.length(data, p, q, end), expected)
        data[p + mismatch] = old
      }
    }
  }
  // Overlapping source/destination ranges (the ordinary repeated-byte
  // match) must also stop at the first mismatch and the valid data end.
  for distance in 1..<=16 {
    for len in 1..<=48 {
      let data = FixedArray::make(distance + len, b'x')
      assert_eq(
        @match_length_fast.length(data, distance, 0, data.length()),
        len,
      )
      data[data.length() - 1] = b'y'
      assert_eq(
        @match_length_fast.length(data, distance, 0, data.length()),
        len - 1,
      )
    }
  }
}
