// Generated from parts/huffman/code_maker_wbtest.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
test "heap_sort sorts any range as a plain sort does" {
  let mut state = 2026UL
  let next = bound => {
    state = state * 6364136223846793005UL + 1442695040888963407UL
    (state >> 33).to_int() % bound
  }
  for len in 0..<300 {
    let base = next(5)
    let a = FixedArray::makei(base + len + 3, _ => next(1 << 20))
    let expected = Array::from_iter(a.iter())
    let middle = expected[base:base + len].to_owned()
    middle.sort()
    for i in 0..<len {
      expected[base + i] = middle[i]
    }
    heap_sort(a, base, len)
    assert_eq(Array::from_iter(a.iter()), expected, msg="length \{len}")
  }
}
