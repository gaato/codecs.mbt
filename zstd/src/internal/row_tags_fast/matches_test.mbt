///|
test "row tag masks equal a plain walk at every head and row size" {
  let mut seed = 2463534242U
  for row_log in 4..<=6 {
    let entries = 1 << row_log
    for round in 0..<40 {
      // Three rows, so a wrong offset reads a neighbour's tags. Few tag
      // values, so most rows hold several matches; every byte value too.
      let tags = FixedArray::makei(3 * entries, _ => {
        seed = seed ^ (seed << 13)
        seed = seed ^ (seed >> 17)
        seed = seed ^ (seed << 5)
        if round % 2 == 0 {
          (seed % 4).to_byte()
        } else {
          (seed >> 24).to_byte()
        }
      })
      let base = entries
      for value in 0..<256 {
        let tag = value.to_byte()
        for head in 0..<entries {
          let mut expected = 0UL
          for k in 0..<entries {
            if tags[base + (head + k) % entries] == tag {
              expected = expected | (1UL << k)
            }
          }
          assert_eq(
            @row_tags_fast.matches(tags, base, tag, head, row_log),
            expected,
          )
        }
      }
    }
  }
}

///|
test "row tag masks at the ends of the table" {
  for row_log in 4..<=6 {
    let entries = 1 << row_log
    let tags = FixedArray::make(2 * entries, b'\x07')
    tags[0] = b'\x01'
    tags[2 * entries - 1] = b'\x01'
    assert_eq(@row_tags_fast.matches(tags, 0, b'\x01', 0, row_log), 1UL)
    assert_eq(
      @row_tags_fast.matches(tags, entries, b'\x01', 0, row_log),
      1UL << (entries - 1),
    )
    assert_eq(
      @row_tags_fast.matches(tags, entries, b'\x01', entries - 1, row_log),
      1UL,
    )
    let all = if entries == 64 {
      0xFFFFFFFFFFFFFFFFUL
    } else {
      (1UL << entries) - 1
    }
    assert_eq(
      @row_tags_fast.matches(tags, 0, b'\x07', 3, row_log),
      all ^ (1UL << (entries - 3)),
    )
  }
}
