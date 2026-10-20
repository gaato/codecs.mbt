///|
/// RFC 7932 section 6's table of block count codes: extra bits and the
/// range of counts of each code.
let block_count_table : Array[(Int32, Int32, Int32)] = [
  (2, 1, 4),
  (2, 5, 8),
  (2, 9, 12),
  (2, 13, 16),
  (3, 17, 24),
  (3, 25, 32),
  (3, 33, 40),
  (3, 41, 48),
  (4, 49, 64),
  (4, 65, 80),
  (4, 81, 96),
  (4, 97, 112),
  (5, 113, 144),
  (5, 145, 176),
  (5, 177, 208),
  (5, 209, 240),
  (6, 241, 304),
  (6, 305, 368),
  (7, 369, 496),
  (8, 497, 752),
  (9, 753, 1264),
  (10, 1265, 2288),
  (11, 2289, 4336),
  (12, 4337, 8432),
  (13, 8433, 16624),
  (24, 16625, 16793840),
]

///|
test "block counts agree with RFC 7932's table" {
  assert_eq(block_count_table.length(), @rules.NUM_BLOCK_COUNT_CODES)
  for code, entry in block_count_table {
    let (extra_bits, first, last) = entry
    assert_eq(@rules.block_count_extra_bits(code), extra_bits)
    let span = 1 << extra_bits
    assert_eq(last - first + 1, span)
    // Every extra value of the shorter codes, the ends of the longest.
    let extras = if extra_bits <= 13 {
      Array::makei(span, i => i)
    } else {
      [0, 1, span / 2, span - 2, span - 1]
    }
    for extra in extras {
      assert_eq(@rules.block_count(code, extra), first + extra)
    }
  }
}

///|
/// A block type code as section 6 describes it: 0 repeats the second-to-last
/// type, 1 is the last type plus one, and the others name type `code - 2`,
/// modulo the number of types.
fn reference_next_block_type(
  code : Int32,
  last : Int32,
  second_last : Int32,
  types : Int32,
) -> Int32 {
  let t = match code {
    0 => second_last
    1 => last + 1
    _ => code - 2
  }
  t % types
}

///|
test "next_block_type agrees with RFC 7932 for every code and pair of types" {
  let check = (types : Int32, current : Int32, previous : Int32) => {
    for code in 0..<(types + 2) {
      assert_eq(
        @rules.next_block_type(code, current~, previous~, types~),
        reference_next_block_type(code, current, previous, types),
      )
    }
  }
  for types in 1..<=16 {
    for current in 0..<types {
      for previous in 0..<types {
        check(types, current, previous)
      }
    }
  }
  for current in [0, 1, 127, 254, 255] {
    for previous in [0, 1, 128, 255] {
      check(256, current, previous)
    }
  }
}
