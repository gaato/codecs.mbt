///|
test "the fixed part: every value of ID1, ID2, CM and FLG" {
  for at in 0..<4 {
    for v in 0..<256 {
      let bytes = b"\x1f\x8b\x08\x00".to_array()
      bytes[at] = v.to_byte()
      let start = Bytes::from_array(bytes)
      let fixed = Bytes::from_array([..bytes, 0, 0, 0, 0, 0, 0])
      // The fixed part is refused exactly when its start is.
      assert_eq(
        @header.check_start(start) is Ok(_),
        @header.parse_fixed(fixed) is Ok(_),
      )
    }
  }
  let base = b"\x1f\x8b\x08\x00\x78\x56\x34\x12\x02\x03".to_array()
  debug_inspect(
    @header.parse_fixed(Bytes::from_array(base)),
    content="Ok({ flags: 0, mtime: 305419896, xfl: 0x02, os: 0x03 })",
  )
  for at in 0..<4 {
    let mut accepted = 0
    for v in 0..<256 {
      let bytes = base.copy()
      bytes[at] = v.to_byte()
      if @header.parse_fixed(Bytes::from_array(bytes)) is Ok(fixed) {
        accepted += 1
        assert_eq(fixed.flags, bytes[3].to_int())
      }
    }
    // One magic number and one method; the flags with no reserved bit.
    assert_eq(accepted, if at == 3 { 32 } else { 1 }, msg="byte \{at}")
  }
}

///|
test "the reasons for refusing a fixed part" {
  debug_inspect(
    @header.parse_fixed(b"\x1f\x8c\x08\x00\x00\x00\x00\x00\x00\x00"),
    content="Err(\"not a gzip stream (the magic number is not 1f 8b)\")",
  )
  debug_inspect(
    @header.parse_fixed(b"\x1f\x8b\x07\x00\x00\x00\x00\x00\x00\x00"),
    content="Err(\"compression method 7 is not DEFLATE (8)\")",
  )
  debug_inspect(
    @header.parse_fixed(b"\x1f\x8b\x08\x20\x00\x00\x00\x00\x00\x00"),
    content="Err(\"reserved header flags are set (FLG 32)\")",
  )
}

///|
test "what may begin another member" {
  inspect(@header.begins_member(b""), content="false")
  inspect(@header.begins_member(b"\x1f"), content="true")
  inspect(@header.begins_member(b"\x1f\x8b"), content="true")
  inspect(@header.begins_member(b"\x1f\x8c"), content="false")
  inspect(@header.begins_member(b"\x00"), content="false")
}

///|
test "the header CRC and the trailer" {
  debug_inspect(
    @header.check_header_crc(0xABCD1234, b"\x34\x12"),
    content="Ok(())",
  )
  debug_inspect(
    @header.check_header_crc(0xABCD1234, b"\x34\x13"),
    content="Err(\"the header's CRC-16 (FHCRC) does not match the header\")",
  )
  debug_inspect(
    @header.check_crc(0x01020304, b"\x04\x03\x02\x01"),
    content="Ok(())",
  )
  debug_inspect(
    @header.check_crc(0x01020305, b"\x04\x03\x02\x01"),
    content="Err(\"the CRC-32 of the data does not match the member's\")",
  )
  debug_inspect(
    @header.check_size(0x05060708, b"\x08\x07\x06\x05"),
    content="Ok(())",
  )
  debug_inspect(
    @header.check_size(0x05060709, b"\x08\x07\x06\x05"),
    content="Err(\"the length of the data does not match the member's (ISIZE)\")",
  )
  inspect(@header.le16(b"\xff\x01"), content="511")
}
