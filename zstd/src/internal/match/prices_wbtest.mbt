///|
test "optimal prices cover predefined costs, fractional weights and block rescaling" {
  for level in [0, 2] {
    let p = Prices::new(true, level)
    p.rescale([b'a'], 0, 1)
    assert_true(p.predefined)
    assert_eq(p.literal(b'a'), 6 * 256)
    assert_eq(p.literal_length(3), if level == 0 { 512 } else { 768 })
    assert_eq(p.match_price(1, 3), if level == 0 { 4096 } else { 4352 })
    let data = FixedArray::makei(16384, i => {
      if i % 3 != 0 {
        b'a'
      } else {
        (i % 251).to_byte()
      }
    })
    p.reset()
    p.rescale(data, 0, data.length())
    assert_false(p.predefined)
    assert_true(p.literal(b'a') < p.literal(b'\xff'))
    assert_eq(p.literal_length(131072), 256 + p.literal_length(131071))
    let mut last = -1
    for stat in 0..<65536 {
      let weight = p.weight(stat)
      assert_true(weight >= last)
      last = weight
    }
    for _ in 0..<5 {
      for _ in 0..<5000 {
        p.update(data, 1, 2, 16, 3)
      }
      p.rescale(data, 0, data.length())
      assert_true(p.lit_sum <= 8192 + 256)
      assert_true(p.ll_sum <= 4096 + 36)
      assert_true(p.ml_sum <= 4096 + 53)
      assert_true(p.of_sum <= 4096 + 32)
      for
        (frequencies, sum) in [
          (p.lit, p.lit_sum),
          (p.ll, p.ll_sum),
          (p.ml, p.ml_sum),
          (p.of, p.of_sum),
        ] {
        let mut actual = 0
        for n in frequencies {
          actual += n
        }
        assert_eq(actual, sum)
      }
    }
    p.reset()
    p.rescale(data, 0, data.length())
    let fresh = Prices::new(true, level)
    fresh.rescale(data, 0, data.length())
    assert_eq(p.lit, fresh.lit)
    assert_eq(p.ll, fresh.ll)
    assert_eq(p.ml, fresh.ml)
    assert_eq(p.of, fresh.of)
    assert_eq(p.lit_base, fresh.lit_base)
  }
}
