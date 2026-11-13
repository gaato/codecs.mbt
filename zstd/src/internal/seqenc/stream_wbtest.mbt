///|
test "table reuse rejects absent symbols and single-symbol compressed tables" {
  let stream = Stream::new(of_default, 32, 8, 5)
  stream.counts[0] = 100
  stream.select(100)
  assert_eq(stream.mode, 1)
  stream.commit()
  stream.select(100)
  assert_eq(stream.mode, 3)
  stream.counts[0] = 0
  stream.counts[31] = 100
  stream.counts[30] = 100
  stream.select(200)
  assert_eq(stream.mode, 2)
  assert_true(stream.log <= 8)
  stream.commit()
  stream.select(200)
  assert_eq(stream.mode, 3)
  stream.counts[1] = 2
  stream.select(202)
  assert_true(stream.mode != 3)
}
