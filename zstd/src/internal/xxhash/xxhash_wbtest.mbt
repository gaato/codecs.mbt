///|
/// On JS, `consume_stripes` computes in 32-bit halves: it must agree with
/// `round` on 64-bit integers for any lanes and bytes, carries included.
test "consume_stripes agrees with round on random lanes and bytes" {
  let mut seed = 0x9E3779B97F4A7C15UL
  fn next() -> UInt64 {
    seed = seed * 6364136223846793005UL + 1442695040888963407UL
    seed
  }
  for _ in 0..<200 {
    let acc = FixedArray::makei(4, _ => next())
    let expected = FixedArray::makei(4, k => acc[k])
    let n = (next() >> 58).to_int() + 1
    let data = FixedArray::makei(32 * n + 5, _ => (next() >> 56).to_byte())
    let start = (next() >> 62).to_int()
    let end = start + 32 * (n - 1) + 31
    let mut i = start
    while end - i >= 32 {
      for k in 0..<4 {
        expected[k] = round(expected[k], read64(data, i + 8 * k))
      }
      i += 32
    }
    assert_eq(consume_stripes(acc, data, start, end), i)
    for k in 0..<4 {
      assert_eq(acc[k], expected[k])
    }
  }
}
