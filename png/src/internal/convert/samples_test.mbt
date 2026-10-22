///|
test "packed_sample: every sample of every byte, at every depth" {
  for depth in [1, 2, 4] {
    let per_byte = 8 / depth
    for byte in 0..<256 {
      let mut rebuilt = 0
      for k in 0..<per_byte {
        let v = @convert.packed_sample(byte, k, depth)
        assert_true(v >= 0 && v < 1 << depth)
        rebuilt = rebuilt * (1 << depth) + v
      }
      assert_eq(rebuilt, byte)
    }
  }
}

///|
test "widen: v × 255 / (2^depth − 1), the bits repeated" {
  for depth in [1, 2, 4, 8] {
    let top = (1 << depth) - 1
    for v in 0..<=top {
      let w = @convert.widen(v, depth)
      assert_eq(w, v * 255 / top)
      assert_eq(w * top, v * 255)
      // The bits repeated: the top `depth` bits are `v`.
      assert_eq(w >> (8 - depth), v)
    }
  }
}

///|
test "narrow: round(v × 255 / 65535), for every 16-bit value" {
  for v in 0..<65536 {
    let n = @convert.narrow(v)
    // The nearest: |n × 65535 − v × 255| ≤ 65535 / 2.
    let error = (n * 65535 - v * 255).abs()
    assert_true(error * 2 <= 65535)
  }
  inspect(@convert.narrow(0), content="0")
  inspect(@convert.narrow(65535), content="255")
  inspect(@convert.narrow(0x8080), content="128")
}
