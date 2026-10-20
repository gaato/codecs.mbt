///|
/// The Kraft sum of `lengths[0..n)` in units of `2^-max_bits`.
fn kraft(lengths : FixedArray[Int32], n : Int32, max_bits : Int32) -> Int32 {
  for s = 0, sum = 0; s < n; {
    let len = lengths[s]
    continue s + 1, if len == 0 { sum } else { sum + (1 << (max_bits - len)) }
  } nobreak {
    sum
  }
}

///|
test "code lengths are optimal when they fit" {
  let freqs : FixedArray[Int32] = [5, 9, 12, 13, 16, 45]
  let lengths = FixedArray::make(6, 0)
  @huffman.code_lengths(freqs, 6, 15, lengths)
  debug_inspect(
    lengths,
    content=(
      #|<FixedArray: [4, 4, 3, 3, 3, 1]>
    ),
  )
}

///|
test "unused symbols get no code and a lone symbol gets one bit" {
  let lengths = FixedArray::make(4, 9)
  @huffman.code_lengths([0, 0, 0, 0], 4, 15, lengths)
  debug_inspect(
    lengths,
    content=(
      #|<FixedArray: [0, 0, 0, 0]>
    ),
  )
  @huffman.code_lengths([0, 7, 0, 0], 4, 15, lengths)
  debug_inspect(
    lengths,
    content=(
      #|<FixedArray: [0, 1, 0, 0]>
    ),
  )
  @huffman.code_lengths([0, 7, 0, 1], 4, 15, lengths)
  debug_inspect(
    lengths,
    content=(
      #|<FixedArray: [0, 1, 0, 1]>
    ),
  )
}

///|
test "code lengths stay within the limit and the code stays complete" {
  // Fibonacci frequencies make the deepest optimal tree.
  let n = 30
  let freqs = FixedArray::make(n, 1)
  for i in 2..<n {
    freqs[i] = freqs[i - 1] + freqs[i - 2]
  }
  let lengths = FixedArray::make(32, 0)
  @huffman.code_lengths(freqs, n, 29, lengths)
  inspect(lengths[0], content="29")
  for max_bits in [5, 7, 15] {
    @huffman.code_lengths(freqs, n, max_bits, lengths)
    for s in 0..<n {
      assert_true(lengths[s] >= 1 && lengths[s] <= max_bits)
    }
    assert_eq(kraft(lengths, n, max_bits), 1 << max_bits)
  }
  // As many symbols as the limit allows: every length is the limit.
  let flat = FixedArray::make(32, 1)
  flat[0] = 1000
  @huffman.code_lengths(flat, 32, 5, lengths)
  for s in 0..<32 {
    assert_eq(lengths[s], 5)
  }
}

///|
test "canonical codes follow RFC 1951 and come out bit-reversed" {
  // The example of RFC 1951 section 3.2.2.
  let lengths : FixedArray[Int32] = [3, 3, 3, 3, 3, 2, 4, 4]
  let codes = FixedArray::make(8, 0)
  @huffman.canonical_codes(lengths, 8, codes)
  let msb_first = [
    for s in 0..<8 => @huffman.reverse_bits(codes[s], lengths[s])
  ]
  debug_inspect(msb_first, content="[2, 3, 4, 5, 6, 0, 14, 15]")
  debug_inspect(
    codes,
    content=(
      #|<FixedArray: [2, 6, 1, 5, 3, 0, 7, 15]>
    ),
  )
  let sparse : FixedArray[Int32] = [0, 1, 0, 1]
  @huffman.canonical_codes(sparse, 4, codes)
  debug_inspect(
    codes[0:4],
    content=(
      #|<ArrayView: [0, 0, 0, 1]>
    ),
  )
}
