// Generated from parts/huffman/enough_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
/// The lengths of the complete code zlib's `enough` reports as taking the
/// most entries: `counts[l]` codes of length `l` longer than the root (as
/// it prints them), and codes of lengths 1, 2, 3, ... filling the rest of
/// the code space with the symbols left.
fn worst(alphabet : Int32, counts : Array[(Int32, Int32)]) -> FixedArray[Int32] {
  let lengths = FixedArray::make(alphabet, 0)
  let mut s = 0
  for c in counts {
    let (count, l) = c
    for _ in 0..<count {
      lengths[s] = l
      s += 1
    }
  }
  for l = 1; s < alphabet; l = l + 1 {
    lengths[s] = l
    s += 1
  }
  lengths
}

///|
test "max_entries: the largest tables are zlib's bounds" {
  // `enough <alphabet> <root> 15` of zlib's examples/enough.c prints the
  // bound and the code that reaches it.
  let cases : Array[(Int32, Int32, Array[(Int32, Int32)])] = [
    (286, 9, [(1, 10), (229, 11), (49, 12), (1, 13), (1, 14), (2, 15)]),
    (288, 10, [(3, 11), (221, 12), (57, 13), (1, 14), (2, 15)]),
    (288, 11, [(3, 12), (221, 13), (57, 14), (2, 15)]),
    (
      30,
      6,
      [
        (1, 7),
        (9, 8),
        (9, 9),
        (1, 10),
        (1, 11),
        (1, 12),
        (1, 13),
        (1, 14),
        (2, 15),
      ],
    ),
    (30, 8, [(1, 9), (9, 10), (9, 11), (1, 12), (1, 13), (1, 14), (2, 15)]),
    (32, 8, [(3, 9), (1, 10), (17, 11), (1, 12), (1, 13), (1, 14), (2, 15)]),
    (256, 8, [(7, 9), (241, 10), (1, 11), (1, 12), (1, 13), (1, 14), (2, 15)]),
  ]
  for c in cases {
    let (alphabet, root, counts) = c
    let lengths = worst(alphabet, counts)
    assert_eq(space(lengths), 32768)
    let size = check(root, lengths)
    assert_eq(Some(size), @huffman.max_entries(alphabet~, root_bits=root))
  }
  debug_inspect(@huffman.max_entries(alphabet=704, root_bits=8), content="None")
}
