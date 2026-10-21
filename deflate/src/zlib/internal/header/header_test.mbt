///|
/// RFC 1950 section 2.2, written out separately: what a decoder must accept.
fn accepts(cmf : Int32, flg : Int32) -> Bool {
  ((cmf << 8) | flg) % 31 == 0 && cmf % 16 == 8 && cmf / 16 <= 7
}

///|
test "every pair of header bytes, against the RFC" {
  let mut accepted = 0
  for cmf in 0..<256 {
    for flg in 0..<256 {
      match @header.parse(cmf.to_byte(), flg.to_byte()) {
        Ok(h) => {
          assert_true(accepts(cmf, flg), msg="\{cmf} \{flg}")
          assert_eq(h.window_bits, cmf / 16 + 8)
          assert_eq(h.level, flg / 64)
          assert_eq(h.dictionary, flg / 32 % 2 == 1)
          accepted += 1
        }
        Err(_) => assert_false(accepts(cmf, flg), msg="\{cmf} \{flg}")
      }
    }
  }
  // 8 windows, and 256 / 31 rounded either way of the FLG values each.
  inspect(accepted, content="66")
}

///|
test "the reasons for refusing a header" {
  debug_inspect(
    @header.parse(b'\x78', b'\x9c'),
    content="Ok({ window_bits: 15, level: 2, dictionary: false })",
  )
  debug_inspect(
    @header.parse(b'\x78', b'\x9d'),
    content="Err(\"the header check (FCHECK) fails\")",
  )
  debug_inspect(
    @header.parse(b'\x77', b'\x85'),
    content="Err(\"compression method 7 is not DEFLATE (8)\")",
  )
  debug_inspect(
    @header.parse(b'\x88', b'\x98'),
    content="Err(\"a window of 2^16 bytes is over 32 KiB\")",
  )
}

///|
test "the trailer" {
  inspect(@header.be32(b"\x12\x34\x56\x78"), content="305419896")
  debug_inspect(
    @header.check_trailer(0x12345678, b"\x12\x34\x56\x78"),
    content="Ok(())",
  )
  debug_inspect(
    @header.check_trailer(0x12345679, b"\x12\x34\x56\x78"),
    content="Err(\"the Adler-32 of the data does not match the stream's\")",
  )
}

///|
test "the header an encoder writes reads back, for every level" {
  for level in -1..<=10 {
    for id in [None, Some(0U), Some(0x12345678U), Some(0xFFFFFFFFU)] {
      let bytes = @header.build(level, id)
      let h = @header.parse(bytes[0], bytes[1]).unwrap()
      let clamped = level.clamp(min=0, max=9)
      let flevel = if clamped < 2 {
        0
      } else if clamped < 6 {
        1
      } else if clamped == 6 {
        2
      } else {
        3
      }
      assert_eq(h, {
        window_bits: 15,
        level: flevel,
        dictionary: id is Some(_),
      })
      match id {
        Some(id) => {
          assert_eq(bytes.length(), 6)
          assert_eq(@header.be32(bytes[2:6]), id)
        }
        None => assert_eq(bytes.length(), 2)
      }
    }
  }
}

///|
test "the header bytes are zlib's" {
  assert_eq(@header.build(0, None), b"\x78\x01")
  assert_eq(@header.build(1, None), b"\x78\x01")
  assert_eq(@header.build(2, None), b"\x78\x5e")
  assert_eq(@header.build(5, None), b"\x78\x5e")
  assert_eq(@header.build(6, None), b"\x78\x9c")
  assert_eq(@header.build(7, None), b"\x78\xda")
  assert_eq(@header.build(9, None), b"\x78\xda")
  assert_eq(@header.build(6, Some(0x12345678)), b"\x78\xbb\x12\x34\x56\x78")
  // A header whose check is already zero gets 31, as zlib's does.
  assert_eq(@header.build(1, Some(1)), b"\x78\x3f\x00\x00\x00\x01")
}

///|
test "put_be32 inverts be32" {
  for value in [0U, 1, 0x12345678, 0x80000000, 0xFFFFFFFF] {
    assert_eq(@header.be32(@header.put_be32(value)), value)
  }
  assert_eq(@header.put_be32(0x01020304), b"\x01\x02\x03\x04")
}
