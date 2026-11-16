///|
test "near-optimal state stays bounded while a split rewinds cached matches" {
  // Random literals, then a long run, then random literals again: the first
  // successful change check rewinds before the differing chunk. This chunk
  // spans more than a window, so sliding at the scan frontier would lose it.
  let mut state = 91U
  let noise = Bytes::makei(60000, _ => {
    state = state * 1664525U + 1013904223U
    (state >> 24).to_byte()
  })
  let input = noise[:20000].to_owned() +
    Bytes::make(40000, b'\x00') +
    noise[20000:].to_owned()
  for level in 10..<=12 {
    let d = Deflater::new(level~)
    let n = d.near.unwrap()
    assert_eq(n.cache.length(), 1280513)
    assert_eq(n.node_cost.length(), 70535)
    assert_eq(n.node_item.length(), 70535)
    assert_eq(n.memory_usage(), 6743444)
    assert_eq(d.seq_litlen.length(), 21931)
    let none = FixedArray::make(0, b'\x00')
    let room = FixedArray::make(4096, b'\x00')
    let out = Buffer()
    let mut pos = 0
    let mut rewound = false
    let mut blocks = 0
    while !d.is_finished() {
      let status = d.step_into(input[pos:], none, action=Finish)
      pos += d.last_consumed()
      if status is NeedMoreOutput {
        rewound = rewound || n.rewind
        blocks += 1
        assert_true(n.cache_len <= n.cache.length())
        assert_true(d.nseq <= d.seq_cap)
        assert_eq(d.memory_usage(), memory_bound(level).to_int())
      }
      ignore(d.step_into(input[pos:], room, action=Finish))
      pos += d.last_consumed()
      out.write_bytes(Bytes::from_array(room[:d.last_produced()]))
    }
    assert_true(rewound, msg="level \{level} did not exercise rewinding")
    assert_true(blocks > 1)
    let inflater = @inflate.Inflater::new()
    let back = FixedArray::make(input.length(), b'\x00')
    assert_eq(inflater.step_into(out.to_bytes(), back, end=true), Done)
    assert_eq(Bytes::from_array(back), input)
    // Both large arrays must keep their element values within a 31-bit Smi;
    // a packed distant match or a forbidden node must not force JS doubles.
    for entry in n.cache {
      assert_true(entry >= 0 && entry < 1 << 24)
    }
    for cost in n.node_cost {
      assert_true(cost < 0x40000000U)
    }
  }
}
