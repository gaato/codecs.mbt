///|
/// CRC-32 bit by bit, as RFC 1952 section 8 defines it, without a table.
fn reference(data : Bytes) -> UInt32 {
  let mut c = 0xFFFFFFFFU
  for byte in data {
    c = c ^ byte.to_uint()
    for _ in 0..<8 {
      c = if (c & 1) != 0 { 0xEDB88320U ^ (c >> 1) } else { c >> 1 }
    }
  }
  c ^ 0xFFFFFFFFU
}

///|
test "known values" {
  inspect(@crc32.update_bytes(@crc32.INITIAL, b""), content="0")
  // The check value of CRC-32/ISO-HDLC.
  inspect(
    @crc32.update_bytes(@crc32.INITIAL, b"123456789"),
    content="3421780262",
  )
}

///|
test "equal to the bitwise reference, whole and in pieces" {
  let data = Bytes::makei(3000, i => (i * 31 + i / 7).to_byte())
  assert_eq(@crc32.update_bytes(@crc32.INITIAL, data), reference(data))
  let array = data.to_array()
  let mut crc = @crc32.INITIAL
  for start = 0; start < array.length(); start = start + 100 {
    crc = @crc32.update(crc, array[start:start + 100])
  }
  assert_eq(crc, reference(data))
  for b in 0..<256 {
    let one = Bytes::make(1, b.to_byte())
    assert_eq(@crc32.update_bytes(@crc32.INITIAL, one), reference(one))
  }
}
