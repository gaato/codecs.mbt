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
