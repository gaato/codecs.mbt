///|
test "bytes and into_view copy exactly the range" {
  let src = FixedArray::makei(40, i => (i + 1).to_byte())
  for n in [0, 1, 7, 8, 9, 31] {
    for at in [0, 3, 40 - n] {
      for to in [0, 5] {
        let dst = FixedArray::make(40, b'\xff')
        @blit.bytes(dst, to, src, at, n)
        let backing = FixedArray::make(48, b'\xff')
        let view = backing.mut_view(start=4, end=44)
        @blit.into_view(view, to, src, at, n)
        for i in 0..<40 {
          let expected = if i >= to && i < to + n {
            src[at + i - to]
          } else {
            b'\xff'
          }
          assert_eq(dst[i], expected)
          assert_eq(backing[4 + i], expected)
        }
        for i in [0, 1, 2, 3, 44, 45, 46, 47] {
          assert_eq(backing[i], b'\xff')
        }
      }
    }
  }
}
