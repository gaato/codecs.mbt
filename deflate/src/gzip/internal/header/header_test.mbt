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

///|
test "a built header reads back, for every combination of fields" {
  let values : Array[Bytes?] = [None, Some(b""), Some(b"x"), Some(b"name.txt")]
  for text in [false, true] {
    for
      extra in [
        None,
        Some(b""),
        Some(b"AB\x02\x00hi"),
        Some(Bytes::make(65535, b'e')),
      ] {
      for name in values {
        for comment in values {
          assert_true(@header.writable(extra, name, comment))
          let bytes = @header.build(
            text~,
            mtime=0x12345678,
            xfl=b'\x02',
            os=b'\x03',
            extra~,
            name~,
            comment~,
          )
          let fixed = @header.parse_fixed(bytes[:@header.FIXED_SIZE]).unwrap()
          let flags = (if text { @header.FTEXT } else { 0 }) |
            (if extra is Some(_) { @header.FEXTRA } else { 0 }) |
            (if name is Some(_) { @header.FNAME } else { 0 }) |
            (if comment is Some(_) { @header.FCOMMENT } else { 0 })
          assert_eq(fixed, {
            flags,
            mtime: 0x12345678,
            xfl: b'\x02',
            os: b'\x03',
          })
          // The variable fields, read as RFC 1952 lays them out.
          let mut at = @header.FIXED_SIZE
          if extra is Some(e) {
            let xlen = @header.le16(bytes[at:at + 2])
            assert_eq(bytes[at + 2:at + 2 + xlen], e)
            at += 2 + xlen
          }
          for field in [name, comment] {
            if field is Some(f) {
              assert_eq(bytes[at:at + f.length()], f)
              assert_eq(bytes[at + f.length()], b'\x00')
              at += f.length() + 1
            }
          }
          assert_eq(at, bytes.length())
        }
      }
    }
  }
}

///|
test "what cannot be written" {
  assert_true(@header.writable(None, None, None))
  assert_false(@header.writable(Some(Bytes::make(65536, b'e')), None, None))
  assert_false(@header.writable(None, Some(b"a\x00b"), None))
  assert_false(@header.writable(None, None, Some(b"\x00")))
  // Zeros in the extra field are its bytes, written with their length.
  assert_true(@header.writable(Some(b"\x00\x00"), Some(b"a"), Some(b"b")))
}

///|
test "the trailer reads back" {
  for value in [(0U, 0U), (0x12345678, 5), (0xFFFFFFFF, 0x80000000)] {
    let (crc, size) = value
    let trailer = @header.trailer(crc, size)
    assert_eq(trailer.length(), 8)
    assert_true(@header.check_crc(crc, trailer[0:4]) is Ok(_))
    assert_true(@header.check_size(size, trailer[4:8]) is Ok(_))
  }
  assert_eq(
    @header.trailer(0x04030201, 0x08070605),
    b"\x01\x02\x03\x04\x05\x06\x07\x08",
  )
}
