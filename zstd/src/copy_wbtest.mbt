///|
/// The window copies against a byte-by-byte copy, for every short distance
/// and length: the bytes up to the end must match, and nothing before the
/// destination may change.
test "window copies match a byte-by-byte copy" {
  for dist in 1..<=20 {
    for n in 0..<=40 {
      let size = 64 + 40 + 8
      let base = FixedArray::makei(size, i => (i * 37 + 11).to_byte())
      let expected = FixedArray::makei(size, i => base[i])
      let dst = 64
      for i in 0..<n {
        expected[dst + i] = expected[dst - dist + i]
      }
      let wild = FixedArray::makei(size, i => base[i])
      wild_match(wild, dst, dist, n)
      let exact = FixedArray::makei(size, i => base[i])
      if dist >= n {
        copy_forward(exact, dst, exact, dst - dist, n)
      } else {
        copy_overlapping(exact, dst, dst - dist, n)
      }
      for i in 0..<(dst + n) {
        assert_eq(wild[i], expected[i], msg="wild dist \{dist} n \{n} at \{i}")
      }
      for i in 0..<size {
        assert_eq(
          exact[i],
          expected[i],
          msg="exact dist \{dist} n \{n} at \{i}",
        )
      }
    }
  }
}

///|
test "literal copies match a byte-by-byte copy" {
  let src = FixedArray::makei(80, i => (i * 13 + 5).to_byte())
  for n in 0..<=40 {
    for from in [0, 3, 32] {
      let a = FixedArray::make(64, b'\xee')
      let b = FixedArray::make(64, b'\xee')
      wild_copy(a, 5, src, from, n)
      copy_forward(b, 5, src, from, n)
      for i in 0..<(5 + n) {
        let expected = if i < 5 { b'\xee' } else { src[from + i - 5] }
        assert_eq(a[i], expected)
        assert_eq(b[i], expected)
      }
      for i in (5 + n)..<64 {
        assert_eq(b[i], b'\xee')
      }
    }
  }
}
