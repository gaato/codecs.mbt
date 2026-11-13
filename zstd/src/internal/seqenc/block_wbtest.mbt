///|
test "sequence storage reaches its RFC block capacity and keeps bounded arrays" {
  let block = Block()
  block.reset(Repeats(), 131072)
  for _ in 0..<(131072 / 3) {
    block.add(0, 3, Distance(1))
  }
  assert_eq(block.count, 43690)
  assert_eq(block.ll.length(), 43690)
  assert_eq(block.ml.length(), 43690)
  assert_eq(block.offsets.length(), 43690)
  assert_eq(block.literals.length(), 131072)
  assert_eq(block.memory_usage(), 655364)
  block.reset(Repeats(), 1)
  assert_eq(block.count, 0)
  assert_eq(block.memory_usage(), 655364)
}
