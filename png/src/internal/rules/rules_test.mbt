///|
fn type_of(name : String) -> UInt32 {
  @rules.chunk_type(
    name[0].to_byte(),
    name[1].to_byte(),
    name[2].to_byte(),
    name[3].to_byte(),
  )
}

///|
/// Table 7 of the Third Edition, written out again: for each chunk, whether
/// several may come, and where it may come, as the positions it may come at
/// in an image without PLTE (`plain`) and with one (`palette`), each from
/// "h" (after IHDR, before PLTE and IDAT), "p" (after PLTE, before IDAT),
/// "i" (right after an IDAT) and "a" (after the IDAT chunks have ended).
priv struct Row {
  name : String
  several : Bool
  plain : String
  palette : String
}

///|
let table_7 : Array[Row] = [
  { name: "cHRM", several: false, plain: "h", palette: "h", },
  { name: "cICP", several: false, plain: "h", palette: "h", },
  { name: "gAMA", several: false, plain: "h", palette: "h", },
  { name: "iCCP", several: false, plain: "h", palette: "h", },
  { name: "mDCV", several: false, plain: "h", palette: "h", },
  { name: "cLLI", several: false, plain: "h", palette: "h", },
  { name: "sBIT", several: false, plain: "h", palette: "h", },
  { name: "sRGB", several: false, plain: "h", palette: "h", },
  { name: "bKGD", several: false, plain: "hp", palette: "p", },
  { name: "tRNS", several: false, plain: "hp", palette: "p", },
  { name: "hIST", several: false, plain: "p", palette: "p", },
  { name: "acTL", several: false, plain: "hp", palette: "hp", },
  { name: "eXIf", several: false, plain: "hp", palette: "hp", },
  { name: "pHYs", several: false, plain: "hp", palette: "hp", },
  { name: "sPLT", several: true, plain: "hp", palette: "hp", },
  { name: "tIME", several: false, plain: "hpia", palette: "hpia", },
  { name: "iTXt", several: true, plain: "hpia", palette: "hpia", },
  { name: "tEXt", several: true, plain: "hpia", palette: "hpia", },
  { name: "zTXt", several: true, plain: "hpia", palette: "hpia", },
  { name: "fcTL", several: true, plain: "hpia", palette: "hpia", },
  { name: "fdAT", several: true, plain: "ia", palette: "ia", },
  // Unknown ancillary chunks: anywhere between IHDR and IEND.
  { name: "abCd", several: true, plain: "hpia", palette: "hpia", },
]

///|
fn position_of(c : Char) -> @rules.Position {
  match c {
    'h' => AfterHeader
    'p' => AfterPalette
    'i' => InData
    _ => AfterData
  }
}

///|
test "place, exhaustively: every ancillary chunk, at every position, once and twice, for every color type, against table 7" {
  for row in table_7 {
    let t = type_of(row.name)
    let index = @rules.known(t)
    let bit = if index >= 0 { 1U << index } else { 0U }
    for color_type in [0, 2, 3, 4, 6] {
      let allowed = if color_type == 3 { row.palette } else { row.plain }
      for c in "hpia" {
        let position = position_of(c)
        let seen = 0U
        let expected : @rules.Verdict = if allowed.contains_char(c) {
          Accept
        } else {
          Ignore
        }
        let got = @rules.place(position, t, seen, color_type)
        if got != expected {
          fail(
            "\{row.name} at \{c} for color type \{color_type}: \{@debug.to_string(got)}",
          )
        }
        // A second copy of a chunk that may come once is left out; fcTL
        // may come once before IDAT and any number of times after.
        let again = @rules.place(position, t, seen | bit, color_type)
        let once = !row.several || (row.name == "fcTL" && c is ('h' | 'p'))
        let expected_again : @rules.Verdict = if once && index >= 0 {
          Ignore
        } else {
          expected
        }
        if again != expected_again {
          fail(
            "a second \{row.name} at \{c} for color type \{color_type}: \{@debug.to_string(again)}",
          )
        }
      }
    }
  }
}

///|
test "place: the critical chunks" {
  let ihdr = type_of("IHDR")
  let plte = type_of("PLTE")
  let idat = type_of("IDAT")
  let iend = type_of("IEND")
  let plte_seen = 1U << @rules.PLTE
  // IHDR first, and only there.
  assert_true(@rules.place(BeforeHeader, ihdr, 0, 0) is Accept)
  for name in ["PLTE", "IDAT", "IEND", "tEXt", "abCd", "ABCD"] {
    assert_true(
      @rules.place(BeforeHeader, type_of(name), 0, 0) is Refuse(Corrupt, _),
    )
  }
  for
    position in [@rules.Position::AfterHeader, AfterPalette, InData, AfterData] {
    assert_true(@rules.place(position, ihdr, 0, 2) is Refuse(Corrupt, _))
    // An unknown critical chunk cannot be skipped.
    assert_true(
      @rules.place(position, type_of("ABCD"), 0, 2) is Refuse(Unsupported, _),
    )
  }
  // IDAT: consecutive, after PLTE in an indexed-color image.
  for color_type in [0, 2, 4, 6] {
    assert_true(@rules.place(AfterHeader, idat, 0, color_type) is Accept)
  }
  assert_true(@rules.place(AfterHeader, idat, 0, 3) is Refuse(Corrupt, _))
  assert_true(@rules.place(AfterPalette, idat, plte_seen, 3) is Accept)
  assert_true(@rules.place(InData, idat, plte_seen, 3) is Accept)
  assert_true(@rules.place(AfterData, idat, 0, 2) is Refuse(Corrupt, _))
  // IEND after IDAT.
  assert_true(@rules.place(AfterHeader, iend, 0, 2) is Refuse(Corrupt, _))
  assert_true(
    @rules.place(AfterPalette, iend, plte_seen, 3) is Refuse(Corrupt, _),
  )
  assert_true(@rules.place(InData, iend, 0, 2) is Accept)
  assert_true(@rules.place(AfterData, iend, 0, 2) is Accept)
  // PLTE: critical in an indexed-color image, else left out where it does
  // not belong.
  for color_type in [2, 3, 6] {
    assert_true(@rules.place(AfterHeader, plte, 0, color_type) is Accept)
  }
  for color_type in [0, 4] {
    assert_true(@rules.place(AfterHeader, plte, 0, color_type) is Ignore)
  }
  for position in [@rules.Position::InData, AfterData] {
    assert_true(@rules.place(position, plte, 0, 3) is Refuse(Corrupt, _))
    assert_true(@rules.place(position, plte, 0, 2) is Ignore)
  }
  assert_true(
    @rules.place(AfterPalette, plte, plte_seen, 3) is Refuse(Corrupt, _),
  )
  assert_true(@rules.place(AfterPalette, plte, plte_seen, 6) is Ignore)
}

///|
test "after: IHDR, PLTE and IDAT move the position on" {
  let idat = type_of("IDAT")
  let plte = type_of("PLTE")
  let text = type_of("tEXt")
  debug_inspect(
    @rules.after(BeforeHeader, type_of("IHDR"), Accept),
    content="AfterHeader",
  )
  debug_inspect(@rules.after(AfterHeader, plte, Accept), content="AfterPalette")
  debug_inspect(@rules.after(AfterHeader, plte, Ignore), content="AfterHeader")
  debug_inspect(@rules.after(AfterHeader, text, Accept), content="AfterHeader")
  debug_inspect(@rules.after(AfterHeader, idat, Accept), content="InData")
  debug_inspect(@rules.after(AfterPalette, idat, Accept), content="InData")
  debug_inspect(@rules.after(InData, idat, Accept), content="InData")
  debug_inspect(@rules.after(InData, text, Ignore), content="AfterData")
  debug_inspect(
    @rules.after(InData, type_of("IEND"), Accept),
    content="AfterData",
  )
  debug_inspect(@rules.after(AfterData, text, Accept), content="AfterData")
}

///|
test "chunk types: letters, the critical bit, names" {
  assert_true(@rules.is_valid_type(type_of("IDAT")))
  assert_true(@rules.is_valid_type(type_of("zTXt")))
  for bad in [b"ID@T", b"IDA[", b"\x00DAT", b"IDA`", b"IDA{"] {
    assert_false(
      @rules.is_valid_type(@rules.chunk_type(bad[0], bad[1], bad[2], bad[3])),
    )
  }
  assert_true(@rules.is_critical(type_of("IHDR")))
  assert_true(@rules.is_critical(type_of("ABCD")))
  assert_false(@rules.is_critical(type_of("tEXt")))
  assert_false(@rules.is_critical(type_of("aBCD")))
  inspect(@rules.type_name(type_of("cICP")), content="cICP")
  debug_inspect(@rules.known(type_of("fdAT")), content="24")
  debug_inspect(@rules.known(type_of("abCd")), content="-1")
}

///|
test "check_header, exhaustively: every color type and bit depth against table 12, and the other fields of table 11" {
  let allowed = []
  for color_type in -1..<=7 {
    for bit_depth in 0..<=17 {
      if @rules.check_header(1, 1, bit_depth, color_type, 0, 0, 0) is None {
        allowed.push("\{color_type}/\{bit_depth}")
      }
    }
  }
  inspect(
    allowed.join(" "),
    content="0/1 0/2 0/4 0/8 0/16 2/8 2/16 3/1 3/2 3/4 3/8 4/8 4/16 6/8 6/16",
  )
  assert_true(
    @rules.check_header(0x7FFFFFFF, 0x7FFFFFFF, 8, 6, 0, 0, 1) is None,
  )
  for size in [(0U, 1U), (1, 0), (0x80000000, 1), (1, 0x80000000)] {
    assert_true(@rules.check_header(size.0, size.1, 8, 0, 0, 0, 0) is Some(_))
  }
  assert_true(@rules.check_header(1, 1, 8, 0, 1, 0, 0) is Some(_))
  assert_true(@rules.check_header(1, 1, 8, 0, 0, 1, 0) is Some(_))
  assert_true(@rules.check_header(1, 1, 8, 0, 0, 0, 2) is Some(_))
  debug_inspect([0, 2, 3, 4, 6].map(@rules.channels), content="[1, 3, 1, 2, 4]")
}

///|
test "row_bytes: packed rows, in 64 bits, against the limit" {
  debug_inspect(@rules.row_bytes(1, 1, 100), content="1")
  debug_inspect(@rules.row_bytes(9, 1, 100), content="2")
  debug_inspect(@rules.row_bytes(3, 2, 100), content="1")
  debug_inspect(@rules.row_bytes(5, 4, 100), content="3")
  debug_inspect(@rules.row_bytes(10, 24, 100), content="30")
  debug_inspect(@rules.row_bytes(1_000_000, 64, 8_000_000), content="8000000")
  // The widest RGBA16 row, more than 2^34 bytes, is refused with its size.
  let refused = try @rules.row_bytes(0x7FFFFFFF, 64, 8_000_000) catch {
    @codec.CodecError(LimitExceeded(limit), _) => limit
    _ => fail("not LimitExceeded")
  } noraise {
    _ => fail("accepted")
  }
  debug_inspect(refused.needed, content="Some(17179869176)")
  debug_inspect(refused.limit, content="8000000")
  assert_true(refused.resource is Memory)
  let over = try @rules.row_bytes(1_000_001, 64, 8_000_000) catch {
    @codec.CodecError(LimitExceeded(limit), _) => limit.needed
    _ => None
  } noraise {
    _ => None
  }
  debug_inspect(over, content="Some(8000008)")
  debug_inspect(@rules.pass_row_bytes(3, 4), content="2")
}

///|
test "Adam7: each pass's columns and rows are those of its lattice, for every size up to 40" {
  for size in 1..<=40 {
    for pass in 0..<7 {
      let x0 = @rules.pass_x(true, pass)
      let dx = @rules.pass_dx(true, pass)
      let y0 = @rules.pass_y(true, pass)
      let dy = @rules.pass_dy(true, pass)
      let mut columns = 0
      let mut rows = 0
      for x in 0..<size {
        if x >= x0 && (x - x0) % dx == 0 {
          columns += 1
        }
        if x >= y0 && (x - y0) % dy == 0 {
          rows += 1
        }
      }
      assert_eq(@rules.pass_columns(true, pass, size), columns)
      assert_eq(@rules.pass_rows(true, pass, size), rows)
    }
    assert_eq(@rules.pass_columns(false, 0, size), size)
    assert_eq(@rules.pass_rows(false, 0, size), size)
  }
  debug_inspect(@rules.passes(true), content="7")
  debug_inspect(@rules.passes(false), content="1")
}

///|
test "Adam7, exhaustively: every position of the 8 x 8 block is in exactly one pass, as 8.2 draws it" {
  let pattern = StringBuilder()
  for y in 0..<8 {
    for x in 0..<8 {
      let mut found = 0
      for pass in 0..<7 {
        let x0 = @rules.pass_x(true, pass)
        let y0 = @rules.pass_y(true, pass)
        if x >= x0 &&
          (x - x0) % @rules.pass_dx(true, pass) == 0 &&
          y >= y0 &&
          (y - y0) % @rules.pass_dy(true, pass) == 0 {
          assert_eq(found, 0)
          found = pass + 1
        }
      }
      pattern.write_string(found.to_string())
    }
    pattern.write_char('\n')
  }
  inspect(
    pattern.to_string(),
    content=(
      #|16462646
      #|77777777
      #|56565656
      #|77777777
      #|36463646
      #|77777777
      #|56565656
      #|77777777
      #|
    ),
  )
}

///|
test "check_frame: inside the image, without wrapping, whole for the default image" {
  assert_true(@rules.check_frame(10, 8, 10, 8, 0, 0, 2, 1, first=true) is None)
  assert_true(@rules.check_frame(10, 8, 3, 2, 7, 6, 0, 0, first=false) is None)
  for
    bad in [
      @rules.check_frame(10, 8, 0, 2, 0, 0, 0, 0, first=false),
      @rules.check_frame(10, 8, 2, 0, 0, 0, 0, 0, first=false),
      @rules.check_frame(10, 8, 4, 2, 7, 0, 0, 0, first=false),
      @rules.check_frame(10, 8, 4, 3, 0, 6, 0, 0, first=false),
      // x + width wraps in 32 bits.
      @rules.check_frame(10, 8, 0xFFFFFFF8, 1, 9, 0, 0, 0, first=false),
      @rules.check_frame(10, 8, 1, 0xFFFFFFFF, 0, 1, 0, 0, first=false),
      @rules.check_frame(10, 8, 9, 8, 1, 0, 0, 0, first=true),
      @rules.check_frame(10, 8, 10, 8, 0, 0, 3, 0, first=false),
      @rules.check_frame(10, 8, 10, 8, 0, 0, 0, 2, first=false),
    ] {
    assert_true(bad is Some(_))
  }
}

///|
test "lattice_count: every start and step of Adam7, every size up to 70, against counting" {
  for step in [1, 2, 4, 8] {
    for start in 0..<8 {
      for size in 0..<=70 {
        let mut n = 0
        for x = start; x < size; x = x + step {
          n += 1
        }
        assert_eq(@rules.lattice_count(size, start, step), n)
      }
    }
  }
  inspect(@rules.lattice_count(0x7FFFFFFF, 7, 8), content="268435455")
}

///|
test "property_bit and is_letter: every byte" {
  for b in 0..<256 {
    assert_eq(@rules.property_bit(b), (b & 0x20) != 0)
    assert_eq(
      @rules.is_letter(b),
      (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A),
    )
  }
}
