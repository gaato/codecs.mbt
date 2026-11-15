// The encoder on its own; its round trips through the decoder are in the
// zstd package's huffman_encode_wbtest.mbt.

///|
test "HuffmanEncoder: memory, and what a build leaves" {
  let encoder = @huffenc.HuffmanEncoder()
  let before = encoder.memory_usage()
  assert_true(before > 0)
  let counts = FixedArray::make(256, 0)
  counts[b'a'.to_int()] = 3
  counts[b'b'.to_int()] = 1
  counts[b'c'.to_int()] = 1
  assert_true(encoder.build(counts))
  inspect(encoder.max_bits(), content="2")
  inspect(encoder.cost(counts), content="7")
  // The weights of 0 to 'b' (98 of them, the last one's implied) are
  // mostly 0: FSE-compressed, in fewer bytes than 50 four-bit pairs.
  inspect(encoder.description_size() < 50, content="true")
  // Four streams go directly to out; only the weights' scratch was kept.
  let out = @bits.BitPacker()
  let data = FixedArray::make(64, b'a')
  encoder.write_literals(out, data, 0, 64, four_streams=true)
  assert_true(encoder.memory_usage() > before)
}

///|
test "HuffmanEncoder::set_weights takes a dictionary's code, forgetting the last" {
  let encoder = @huffenc.HuffmanEncoder()
  let counts = FixedArray::make(256, 0)
  for s in 0..<200 {
    counts[s] = s + 1
  }
  assert_true(encoder.build(counts))
  // Two symbols of weight 1: one bit each, and nothing for the others the
  // last build coded.
  encoder.set_weights([1, 1], 2)
  assert_eq(encoder.max_bits(), 1)
  let two = FixedArray::make(256, 0)
  two[0] = 3
  two[1] = 5
  assert_true(encoder.accepts(two))
  assert_eq(encoder.cost(two), 8)
  two[2] = 1
  assert_false(encoder.accepts(two))
}
