///|
/// RFC 7932 section 9.1's table: each WBITS and its bit pattern, as the RFC
/// prints it, first bit rightmost.
let wbits_table : Array[(Int32, String)] = [
  (10, "0100001"),
  (11, "0110001"),
  (12, "1000001"),
  (13, "1010001"),
  (14, "1100001"),
  (15, "1110001"),
  (16, "0"),
  (17, "0000001"),
  (18, "0011"),
  (19, "0101"),
  (20, "0111"),
  (21, "1001"),
  (22, "1011"),
  (23, "1101"),
  (24, "1111"),
]

///|
/// The pattern the RFC calls invalid; RFC 9841 makes it large-window Brotli.
let large_window_pattern : String = "0010001"

///|
/// A printed bit pattern as a number.
fn pattern_value(pattern : String) -> Int32 {
  for c in pattern; v = 0 {
    continue v * 2 + (if c == '1' { 1 } else { 0 })
  } nobreak {
    v
  }
}

///|
/// Whether the first bits of `header` are `pattern`.
fn pattern_matches(header : Int32, pattern : String) -> Bool {
  let len = pattern.length()
  header % (1 << len) == pattern_value(pattern)
}

///|
test "window_bits agrees with RFC 7932's table for every 7-bit header" {
  for header in 0..<128 {
    let matches = wbits_table.filter(e => pattern_matches(header, e.1))
    let expected = if pattern_matches(header, large_window_pattern) {
      assert_eq(matches.length(), 0)
      None
    } else {
      // The code is prefix-free: exactly one pattern starts each header.
      assert_eq(matches.length(), 1)
      Some((matches[0].0, matches[0].1.length()))
    }
    assert_eq(@rules.window_bits(header), expected)
  }
}

///|
test "window_bits ignores the bits after the header" {
  for header in 0..<128 {
    let (wbits, length) = @rules.window_bits(header).unwrap_or((0, 0))
    let low = header % (1 << length)
    if wbits > 0 {
      assert_eq(@rules.window_bits(low), Some((wbits, length)))
    }
  }
  debug_inspect(@rules.window_bits(0b0010001), content="None")
  debug_inspect(@rules.window_bits(0b1010001), content="Some((13, 7))")
}

///|
/// MLEN as section 9.2 describes it: the nibbles of MLEN - 1, least
/// significant first, rejected when there are more than four and the last
/// is zero.
fn reference_meta_block_length(nibbles : Array[Int32]) -> Int32? {
  let n = nibbles.length()
  if n > 4 && nibbles[n - 1] == 0 {
    return None
  }
  for i, v in nibbles; len = 0 {
    continue len + v * (1 << (4 * i))
  } nobreak {
    Some(len + 1)
  }
}

///|
/// The `count` digits in base `1 << width` of `value`, least significant
/// first.
fn digits(value : Int32, count : Int32, width : Int32) -> Array[Int32] {
  [
    for i in 0..<count => (value >> (width * i)) % (1 << width)
  ]
}

///|
test "meta_block_length: every 4-nibble length, and the last nibble of longer ones" {
  for bits in 0..<(1 << 16) {
    assert_eq(
      @rules.meta_block_length(bits, 4),
      reference_meta_block_length(digits(bits, 4, 4)),
    )
  }
  let lows = [0, 1, 0x1234, 0xffff, 0x7_ffff, 0xf_ffff]
  for nibbles in 5..<=6 {
    for last in 0..<16 {
      for low in lows {
        let low = low % (1 << (4 * (nibbles - 1)))
        let bits = (last << (4 * (nibbles - 1))) | low
        assert_eq(
          @rules.meta_block_length(bits, nibbles),
          reference_meta_block_length(digits(bits, nibbles, 4)),
        )
      }
    }
  }
  debug_inspect(
    @rules.meta_block_length(0xff_ffff, 6),
    content="Some(16777216)",
  )
}

///|
/// The length of a metadata block as section 9.2 describes it: no bytes
/// mean an empty block; otherwise the bytes of MSKIPLEN - 1, rejected when
/// there are more than one and the last is zero.
fn reference_metadata_length(bytes : Array[Int32]) -> Int32? {
  let n = bytes.length()
  if n == 0 {
    return Some(0)
  }
  if n > 1 && bytes[n - 1] == 0 {
    return None
  }
  for i, v in bytes; len = 0 {
    continue len + v * (1 << (8 * i))
  } nobreak {
    Some(len + 1)
  }
}

///|
test "metadata_length: every length of up to two bytes, and the last byte of three" {
  assert_eq(@rules.metadata_length(0, 0), Some(0))
  for count in 1..<=2 {
    for bits in 0..<(1 << (8 * count)) {
      assert_eq(
        @rules.metadata_length(bits, count),
        reference_metadata_length(digits(bits, count, 8)),
      )
    }
  }
  for last in 0..<256 {
    for low in [0, 1, 0x1234, 0xffff] {
      let bits = (last << 16) | low
      assert_eq(
        @rules.metadata_length(bits, 3),
        reference_metadata_length(digits(bits, 3, 8)),
      )
    }
  }
}
