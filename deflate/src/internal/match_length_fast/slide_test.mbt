// Generated from parts/match_length_fast/slide_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
test "slide moves every value 32 KiB down, saturating at -32768" {
  // Every Int16, in a table whose length is not a multiple of eight, so that
  // the eight-lane loop and the loop after it both run.
  let n = 65536 + 5
  let table = FixedArray::makei(n, i => Int16::from_int(i % 65536 - 32768))
  @match_length_fast.slide(table)
  for i in 0..<n {
    let v = i % 65536 - 32768
    assert_eq(table[i].to_int(), v.max(0) - 32768)
  }
}
