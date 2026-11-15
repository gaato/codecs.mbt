///|
test "Kraft shapes at the decoder's largest alphabet" {
  let lengths = FixedArray::make(704, 0)
  let counts = FixedArray::make(16, 0)
  assert_true(
    @prefix_code.code_shape(lengths, 704, counts) is @prefix_code.Other,
  )
  // Split 192 of a full 512-leaf, depth-nine tree: 320 leaves remain at
  // depth nine and 384 at depth ten. Their Kraft sum is 320/512 + 384/1024.
  for i in 0..<704 {
    lengths[i] = if i < 320 { 9 } else { 10 }
  }
  assert_true(
    @prefix_code.code_shape(lengths, 704, counts) is @prefix_code.Complete,
  )
  // Shortening a leaf over-subscribes the same tree; lengthening it leaves
  // a gap. Reuse scratch space so each call must discard its old counts.
  lengths[0] = 8
  assert_true(
    @prefix_code.code_shape(lengths, 704, counts) is @prefix_code.Other,
  )
  lengths[0] = 10
  assert_true(
    @prefix_code.code_shape(lengths, 704, counts) is @prefix_code.Other,
  )
  lengths.fill(0)
  lengths[703] = 15
  assert_true(
    @prefix_code.code_shape(lengths, 704, counts) is @prefix_code.Single,
  )
  lengths.fill(1)
  assert_true(
    @prefix_code.code_shape(lengths, 704, counts) is @prefix_code.Other,
  )
}
