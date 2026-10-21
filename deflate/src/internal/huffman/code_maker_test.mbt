// Generated from parts/huffman/code_maker_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// `CodeMaker` against the properties of huffman_spec_test.mbt (whose
// helpers it uses): lengths within the limit, a complete code, optimal when
// the limit does not bind, and canonical codewords.

///|
test "CodeMaker: within the limit, complete, canonical, and optimal when nothing is cut" {
  let rng = Rng::{ state: 1951, }
  let maker = @huffman.CodeMaker(max_alphabet=288)
  for round in 0..<3000 {
    let n = 2 + rng.next(287)
    let freqs = random_freqs(rng, n)
    // Keep the frequencies' sum below the bound.
    for s in 0..<n {
      freqs[s] = freqs[s] & 0x3fff
    }
    let used = freqs.iter().filter(f => f > 0).count()
    let mut max_bits = 1 + rng.next(15)
    while 1 << max_bits < n {
      max_bits += 1
    }
    let lengths = FixedArray::make(n, -1)
    let codes = FixedArray::make(n, -1)
    maker.make(freqs, n, max_bits, lengths, codes)
    for s in 0..<n {
      if freqs[s] == 0 && used >= 2 {
        assert_eq(lengths[s], 0)
      } else if freqs[s] != 0 {
        assert_true(lengths[s] >= 1 && lengths[s] <= max_bits)
      }
    }
    // Always complete, with at least two codewords.
    assert_eq(kraft_sum(lengths), 1L << 30)
    let canonical = FixedArray::make(n, 0)
    @huffman.canonical_codes(lengths, n, canonical)
    assert_eq(codes, canonical, msg="round \{round}")
    if used <= 16 && used >= 2 && round % 2 == 0 {
      maker.make(freqs, n, 15, lengths, codes)
      assert_eq(cost(freqs, lengths), optimal_cost(freqs))
    }
  }
}

///|
test "CodeMaker: fewer than two used symbols give two one-bit codewords" {
  let maker = @huffman.CodeMaker(max_alphabet=8)
  let lengths = FixedArray::make(8, 9)
  let codes = FixedArray::make(8, 9)
  maker.make([0, 0, 0, 0, 0, 0, 0, 0], 8, 7, lengths, codes)
  debug_inspect(lengths, content="<FixedArray: [1, 1, 0, 0, 0, 0, 0, 0]>")
  maker.make([0, 0, 0, 0, 0, 3, 0, 0], 8, 7, lengths, codes)
  debug_inspect(lengths, content="<FixedArray: [1, 0, 0, 0, 0, 1, 0, 0]>")
  debug_inspect(codes, content="<FixedArray: [0, 0, 0, 0, 0, 1, 0, 0]>")
  maker.make([4, 0, 0, 0, 0, 0, 0, 0], 8, 7, lengths, codes)
  debug_inspect(lengths, content="<FixedArray: [1, 1, 0, 0, 0, 0, 0, 0]>")
}

///|
test "CodeMaker: the limit pushes long codes down, as libdeflate does" {
  // Fibonacci frequencies make a code as deep as it can be.
  let freqs : FixedArray[Int32] = [1, 1, 2, 3, 5, 8, 13, 21, 34, 55]
  let maker = @huffman.CodeMaker(max_alphabet=10)
  let lengths = FixedArray::make(10, 0)
  let codes = FixedArray::make(10, 0)
  maker.make(freqs, 10, 15, lengths, codes)
  debug_inspect(lengths, content="<FixedArray: [9, 9, 8, 7, 6, 5, 4, 3, 2, 1]>")
  maker.make(freqs, 10, 5, lengths, codes)
  debug_inspect(lengths, content="<FixedArray: [5, 5, 5, 5, 5, 5, 5, 5, 2, 1]>")
  assert_eq(kraft_sum(lengths), 1L << 30)
  inspect(maker.memory_usage(), content="208")
}

///|
test "panic CodeMaker: an alphabet over 1024 symbols aborts" {
  ignore(@huffman.CodeMaker(max_alphabet=1025))
}
