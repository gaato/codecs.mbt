// Generated from parts/crc32c/crc32c_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
/// CRC-32C bit by bit (RFC 3720 appendix B.4), without a table.
fn reference(data : Bytes) -> UInt32 {
  let mut c = 0xFFFFFFFFU
  for byte in data {
    c = c ^ byte.to_uint()
    for _ in 0..<8 {
      c = if (c & 1) != 0 { 0x82F63B78U ^ (c >> 1) } else { c >> 1 }
    }
  }
  c ^ 0xFFFFFFFFU
}

///|
test "known values" {
  inspect(@crc32c.update_bytes(@crc32c.INITIAL, b""), content="0")
  // The check value of CRC-32/ISCSI.
  inspect(
    @crc32c.update_bytes(@crc32c.INITIAL, b"123456789"),
    content="3808858755",
  )
}

///|
test "equal to the bitwise reference, whole and in pieces" {
  let data = Bytes::makei(3000, i => (i * 31 + i / 7).to_byte())
  assert_eq(@crc32c.update_bytes(@crc32c.INITIAL, data), reference(data))
  let array = data.to_array()
  let mut crc = @crc32c.INITIAL
  for start = 0; start < array.length(); start = start + 100 {
    crc = @crc32c.update(crc, array[start:start + 100])
  }
  assert_eq(crc, reference(data))
  for b in 0..<256 {
    let one = Bytes::make(1, b.to_byte())
    assert_eq(@crc32c.update_bytes(@crc32c.INITIAL, one), reference(one))
  }
}

///|
test "eight bytes at a time: every length up to 64, from every alignment" {
  let data = Bytes::makei(80, i => (i * 151 + 7).to_byte())
  let array = data.to_array()
  for start in 0..<8 {
    for len in 0..<=64 {
      let piece = data[start:start + len]
      let expected = reference(piece.to_owned())
      assert_eq(@crc32c.update_bytes(@crc32c.INITIAL, piece), expected)
      assert_eq(
        @crc32c.update(@crc32c.INITIAL, array[start:start + len]),
        expected,
      )
      // Continued from a CRC so far, as chunks of a stream are.
      let split = len / 3
      let head = @crc32c.update_bytes(@crc32c.INITIAL, piece[:split])
      assert_eq(@crc32c.update_bytes(head, piece[split:]), expected)
    }
  }
}
