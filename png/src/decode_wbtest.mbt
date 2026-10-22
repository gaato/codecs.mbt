///|
/// Every color type with every bit depth table 12 allows.
let formats : Array[(Int32, Int32)] = [
  (0, 1),
  (0, 2),
  (0, 4),
  (0, 8),
  (0, 16),
  (2, 8),
  (2, 16),
  (3, 1),
  (3, 2),
  (3, 4),
  (3, 8),
  (4, 8),
  (4, 16),
  (6, 8),
  (6, 16),
]

///|
test "every color type and bit depth, every size up to 8 x 8, interlaced or not" {
  for format in formats {
    let (color_type, bit_depth) = format
    for interlaced in [false, true] {
      for width in 1..<=8 {
        for height in 1..<=8 {
          let (png, raw) = image(
            width,
            height,
            bit_depth,
            color_type,
            interlaced~,
            seed=(width * 8 + height).reinterpret_as_uint(),
          )
          let label = "\{color_type}/\{bit_depth} \{width}x\{height} \{interlaced}"
          for split in [(1 << 20, 1 << 16), (1, 1), (3, 7)] {
            let (chunk, room) = split
            let decoded = run(Decoder(), png, chunk~, room~)
            if decoded.error is Some((kind, message)) {
              fail("\{label}: \{@debug.to_string(kind)} \{message}")
            }
            if decoded.output != raw.rows {
              fail("\{label} in \{chunk}, \{room}: other rows")
            }
            if decoded.consumed != png.length() {
              fail("\{label}: consumed \{decoded.consumed}")
            }
          }
        }
      }
    }
  }
}

///|
test "the answers: Header, Frame, the rows of each pass, FrameEnd, Done" {
  let (png, _) = image(5, 3, 8, 0, interlaced=true)
  let decoder = Decoder()
  inspect(
    outline(run(decoder, png)),
    content="Header Frame Rows 0 0+1 Rows 1 0+1 Rows 3 0+1 Rows 4 0+1 Rows 5 0+2 Rows 6 0+1 FrameEnd Done",
  )
  // Pass 2 starts at row 4: a 3-row image has none of it. The accessors
  // follow the image.
  inspect(decoder.width(), content="5")
  inspect(decoder.height(), content="3")
  inspect(decoder.bit_depth(), content="8")
  debug_inspect(decoder.color_type(), content="Grayscale")
  inspect(decoder.interlaced(), content="true")
  inspect(decoder.ignored_chunks(), content="0")
  // A slice of one row's room gives one row a step; a big one, every row of
  // a pass.
  let (png, raw) = image(4, 6, 8, 2)
  inspect(
    outline(run(Decoder(), png, room=12)),
    content="Header Frame Rows 0 0+1 Rows 0 1+1 Rows 0 2+1 Rows 0 3+1 Rows 0 4+1 Rows 0 5+1 FrameEnd Done",
  )
  inspect(
    outline(run(Decoder(), png, room=30)),
    content="Header Frame Rows 0 0+2 Rows 0 2+2 Rows 0 4+2 FrameEnd Done",
  )
  // A slice shorter than a row takes nothing.
  let decoder = Decoder()
  let mut rest = png[:]
  let short = FixedArray::make(11, b'\x00')
  for _ in 0..<2 {
    let _ = decoder.step(rest, short.mut_view(), end=true)
    rest = rest[decoder.last_consumed():]
  }
  inspect(decoder.room_needed(), content="12")
  debug_inspect(
    decoder.step(rest, short.mut_view(), end=true),
    content="NeedMoreOutput",
  )
  inspect(decoder.last_produced(), content="0")
  assert_eq(run(Decoder(), png).output, raw.rows)
}

///|
test "the accessors of a step's rows: the pass's lattice, the rows' place and size" {
  let (png, _) = image(10, 9, 4, 3, interlaced=true)
  let decoder = Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let seen = []
  let mut input = png[:]
  for ;; {
    let status = decoder.step(input, out.mut_view(), end=true)
    input = input[decoder.last_consumed():]
    match status {
      Rows =>
        seen.push(
          "\{decoder.pass()}: \{decoder.pass_x()},\{decoder.pass_y()} by \{decoder.pass_dx()},\{decoder.pass_dy()} rows \{decoder.rows_first()}+\{decoder.rows_count()} of \{decoder.row_bytes()}",
        )
      Frame => {
        seen.push(
          "frame \{decoder.frame_x()},\{decoder.frame_y()} \{decoder.frame_width()}x\{decoder.frame_height()}",
        )
        inspect(decoder.palette().length(), content="48")
        inspect(decoder.room_needed(), content="1")
      }
      Done => break
      _ => ()
    }
  }
  inspect(
    seen.join("\n"),
    content=(
      #|frame 0,0 10x9
      #|0: 0,0 by 8,8 rows 0+2 of 1
      #|1: 4,0 by 8,8 rows 0+2 of 1
      #|2: 0,4 by 4,8 rows 0+1 of 2
      #|3: 2,0 by 4,4 rows 0+3 of 1
      #|4: 0,2 by 2,4 rows 0+2 of 3
      #|5: 1,0 by 2,2 rows 0+5 of 3
      #|6: 0,1 by 1,2 rows 0+4 of 5
    ),
  )
}

///|
test "the image data in IDAT chunks of every size, split anyhow" {
  let (png, raw) = image(13, 11, 16, 6, interlaced=true)
  for size in [1, 2, 7, 100] {
    let (png, _) = image(13, 11, 16, 6, interlaced=true, idat_size=size)
    for chunk in [1, 5, 1000] {
      let decoded = run(Decoder(), png, chunk~, room=1)
      assert_true(decoded.error is None)
      assert_eq(decoded.output, raw.rows)
    }
  }
  assert_eq(run(Decoder(), png).output, raw.rows)
}

///|
/// The first error of `input`, as kind and message.
fn refusal(input : Bytes, chunk~ : Int32 = 1 << 20) -> String raise {
  match run(Decoder(), input, chunk~).error {
    Some((kind, message)) => "\{@debug.to_string(kind)}: \{message}"
    None => "decoded"
  }
}

///|
/// An 8 x 2 grayscale image's chunks, but for `idat`.
fn gray_with(idat : Array[Array[Byte]]) -> Bytes {
  png_of([chunk("IHDR", ihdr_data(8, 2, 8, 0)), ..idat, chunk("IEND", b"")])
}

///|
test "refusals: the signature, IHDR and the chunks' frame" {
  inspect(
    refusal(b"\x89PNG\r\n\x1a\x0a"),
    content="Truncated: the input ends inside the image",
  )
  inspect(refusal(b""), content="Truncated: the input holds no image")
  // A wrong byte is refused as soon as it comes.
  inspect(
    refusal(b"\x89PNX"),
    content="Corrupt: the input does not begin with PNG's signature",
  )
  inspect(
    refusal(b"GIF89a", chunk=1),
    content="Corrupt: the input does not begin with PNG's signature",
  )
  let ihdr = ihdr_data(8, 2, 8, 0)
  inspect(
    refusal(png_of([chunk("IHDR", ihdr, bad_crc=1)])),
    content="ChecksumMismatch: the CRC of IHDR does not match",
  )
  inspect(
    refusal(png_of([chunk("IHDR", ihdr_data(8, 2, 8, 1))])),
    content="Corrupt: IHDR: color type 1 with bit depth 8",
  )
  inspect(
    refusal(png_of([chunk("IHDR", ihdr_data(0, 2, 8, 0))])),
    content="Corrupt: IHDR: an image of 0x2 pixels",
  )
  inspect(
    refusal(png_of([chunk("IHDR", ihdr_data(8, 2, 3, 2))])),
    content="Corrupt: IHDR: color type 2 with bit depth 3",
  )
  inspect(
    refusal(png_of([chunk("IHDR", ihdr_data(8, 2, 8, 0, interlace=2))])),
    content="Corrupt: IHDR: interlace method 2",
  )
  inspect(
    refusal(png_of([chunk("IHDR", ihdr[:12].to_owned())])),
    content="Corrupt: an IHDR of 12 bytes",
  )
  inspect(
    refusal(png_of([chunk("tEXt", b"a\x00b")])),
    content="Corrupt: the first chunk is tEXt, not IHDR",
  )
  inspect(
    refusal(png_of([chunk("IHDR", ihdr), chunk("IHDR", ihdr)])),
    content="Corrupt: a second IHDR",
  )
  inspect(
    refusal(png_of([chunk("IHDR", ihdr), chunk("ABCD", b"")])),
    content="Unsupported: unknown critical chunk ABCD",
  )
  inspect(
    refusal(png_of([chunk("IHDR", ihdr), chunk("ab1d", b"")])),
    content="Corrupt: a chunk type that is not four letters",
  )
  inspect(
    refusal(
      png_of([
        chunk("IHDR", ihdr),
        [b'\x80', b'\x00', b'\x00', b'\x00', ..type_bytes("tEXt")],
      ]),
    ),
    content="Corrupt: a chunk's length of 2147483648 bytes",
  )
  inspect(
    refusal(png_of([chunk("IHDR", ihdr), chunk("IEND", b"")])),
    content="Corrupt: no IDAT before IEND",
  )
}

///|
test "refusals: PLTE" {
  let indexed = chunk("IHDR", ihdr_data(2, 1, 8, 3))
  let data = idat_chunks(@zlib.compress(b"\x00\x00\x01"), 100)
  inspect(
    refusal(png_of([indexed, ..data, chunk("IEND", b"")])),
    content="Corrupt: an indexed-color image without PLTE before IDAT",
  )
  for bad in [b"", b"\x00\x00", Bytes::make(771, b'\x00')] {
    inspect(
      refusal(png_of([indexed, chunk("PLTE", bad), ..data, chunk("IEND", b"")])),
      content="Corrupt: a PLTE of \{bad.length()} bytes",
    )
  }
  let palette = chunk("PLTE", b"\x01\x02\x03\x04\x05\x06")
  inspect(
    refusal(png_of([indexed, palette, palette, ..data, chunk("IEND", b"")])),
    content="Corrupt: a second PLTE",
  )
  inspect(
    refusal(png_of([indexed, palette, ..data, palette, chunk("IEND", b"")])),
    content="Corrupt: a second PLTE",
  )
  inspect(
    refusal(
      png_of(
        [
          indexed,
          chunk("PLTE", b"\x01\x02\x03", bad_crc=1),
          ..data,
          chunk("IEND", b""),
        ],
      ),
    ),
    content="ChecksumMismatch: the CRC of PLTE does not match",
  )
  // The palette, cut to what 1-bit indices reach.
  let decoder = Decoder()
  let one_bit = png_of(
    [
      chunk("IHDR", ihdr_data(2, 1, 1, 3)),
      chunk("PLTE", b"\x01\x02\x03\x04\x05\x06\x07\x08\x09"),
      ..idat_chunks(@zlib.compress(b"\x00\x40"), 100),
      chunk("IEND", b""),
    ],
  )
  assert_true(run(decoder, one_bit).error is None)
  debug_inspect(
    decoder.palette().to_owned(),
    content="[0x01, 0x02, 0x03, 0x04, 0x05, 0x06]",
  )
}

///|
test "refusals: the image data" {
  let rows = b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x02\x01\x01\x01\x01\x01\x01\x01\x01"
  let zlib = @zlib.compress(rows)
  // What the image needs, whole: decodes.
  assert_true(run(Decoder(), gray_with(idat_chunks(zlib, 5))).error is None)
  inspect(
    refusal(gray_with(idat_chunks(@zlib.compress(rows[:17]), 100))),
    content="Corrupt: the zlib stream ends before the image's last row",
  )
  inspect(
    refusal(gray_with(idat_chunks(zlib[:zlib.length() - 4].to_owned(), 100))),
    content="Corrupt: the zlib stream does not end in the IDAT chunks",
  )
  inspect(
    refusal(gray_with(idat_chunks(zlib[:10].to_owned(), 100))),
    content="Corrupt: the image data ends before the image's last row",
  )
  let bad_adler = zlib.to_array()
  bad_adler[bad_adler.length() - 1] = bad_adler[bad_adler.length() - 1] ^ 1
  inspect(
    refusal(gray_with(idat_chunks(Bytes::from_array(bad_adler), 100))),
    content="ChecksumMismatch: IDAT: the Adler-32 of the data does not match the stream's",
  )
  inspect(
    refusal(gray_with([chunk("IDAT", b"\x78\x9c\xff\xff")])),
    content="Corrupt: IDAT: a block of the reserved type (BTYPE 3)",
  )
  inspect(
    refusal(gray_with([chunk("IDAT", zlib, bad_crc=1)])),
    content="ChecksumMismatch: the CRC of IDAT does not match",
  )
  let bad_filter = rows.to_array()
  bad_filter[9] = b'\x05'
  inspect(
    refusal(
      gray_with(idat_chunks(@zlib.compress(Bytes::from_array(bad_filter)), 100)),
    ),
    content="Corrupt: filter type 5",
  )
  inspect(
    refusal(
      png_of([
        chunk("IHDR", ihdr_data(8, 2, 8, 0)),
        chunk("IDAT", zlib[:6].to_owned()),
        chunk("tEXt", b"a\x00b"),
        chunk("IDAT", zlib[6:].to_owned()),
        chunk("IEND", b""),
      ]),
    ),
    content="Corrupt: the image data ends before the image's last row",
  )
}

///|
test "the image data: more than the rows need is inflated and dropped, bytes after the stream dropped" {
  let rows = b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x02\x01\x01\x01\x01\x01\x01\x01\x01"
  let decoded = run(
    Decoder(),
    gray_with(idat_chunks(@zlib.compress(rows), 100)),
  )
  // Inflated data past the last row.
  let longer = run(
    Decoder(),
    gray_with(
      idat_chunks(@zlib.compress([..rows, ..Bytes::make(5000, b'\x07')]), 100),
    ),
  )
  assert_true(longer.error is None)
  assert_eq(longer.output, decoded.output)
  // Bytes after the zlib stream, in its IDAT and in IDAT chunks after it.
  let zlib = @zlib.compress(rows)
  let after = run(
    Decoder(),
    gray_with([
      chunk("IDAT", Bytes::from_array([..zlib, b'\x01', b'\x02'])),
      chunk("IDAT", b"junk"),
    ]),
    chunk=1,
    room=8,
  )
  assert_true(after.error is None)
  assert_eq(after.output, decoded.output)
  // Their CRC still counts.
  inspect(
    refusal(gray_with([chunk("IDAT", zlib), chunk("IDAT", b"junk", bad_crc=1)])),
    content="ChecksumMismatch: the CRC of IDAT does not match",
  )
}

///|
test "rows come before the checks that cover them, and the error after them" {
  let (png, raw) = image(4, 6, 8, 0)
  // The image data's CRC, last in the image's IDAT.
  let at = png.length() - 12 - 4
  let broken = png.to_array()
  broken[at] = broken[at] ^ 0xFF
  let decoded = run(Decoder(), Bytes::from_array(broken), room=4)
  inspect(
    outline(decoded),
    content="Header Frame Rows 0 0+1 Rows 0 1+1 Rows 0 2+1 Rows 0 3+1 Rows 0 4+1 Rows 0 5+1",
  )
  assert_eq(decoded.output, raw.rows)
  debug_inspect(decoded.error.map(e => e.0), content="Some(ChecksumMismatch)")
  // Rows written in the step that finds an error come out first; the next
  // step raises it.
  let decoder = Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let input = Bytes::from_array(broken)
  let mut rest = input[:]
  let mut status = decoder.step(rest, out.mut_view(), end=true)
  while !(status is Rows) {
    rest = rest[decoder.last_consumed():]
    status = decoder.step(rest, out.mut_view(), end=true)
  }
  inspect(decoder.rows_count(), content="6")
  rest = rest[decoder.last_consumed():]
  let kind = try decoder.step(rest, out.mut_view(), end=true) catch {
    CodecError(kind, _) => Some(kind)
  } noraise {
    _ => None
  }
  debug_inspect(kind, content="Some(ChecksumMismatch)")
  // It consumed the CRC it found wrong, and wrote nothing.
  inspect(decoder.last_consumed(), content="4")
  inspect(decoder.last_produced(), content="0")
}

///|
test "ancillary chunks: skipped, and left out and counted where they do not belong" {
  let rows = b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x00\x01\x01\x01\x01\x01\x01\x01\x01"
  let zlib = idat_chunks(@zlib.compress(rows), 100)
  let ihdr = chunk("IHDR", ihdr_data(8, 2, 8, 0))
  let gama = chunk("gAMA", Bytes::from_array(be32(45455)))
  let decoder = Decoder()
  let decoded = run(
    decoder,
    png_of(
      [
        ihdr,
        gama,
        chunk("abCd", b"unknown"),
        ..zlib,
        chunk("tEXt", b"after\x00data"),
        chunk("IEND", b""),
      ],
    ),
  )
  assert_true(decoded.error is None)
  inspect(decoder.ignored_chunks(), content="0")
  let plain = decoded.output
  // A second gAMA, a gAMA after IDAT, a bad CRC, PLTE in a grayscale image,
  // IEND with data: left out, counted, and the rows are the same.
  let decoder = Decoder()
  let decoded = run(
    decoder,
    png_of(
      [
        ihdr,
        gama,
        gama,
        chunk("cHRM", Bytes::make(32, b'\x00'), bad_crc=1),
        chunk("PLTE", b"\x00\x00\x00"),
        chunk("abCd", b"unknown", bad_crc=1),
        ..zlib,
        gama,
        chunk("IEND", b"x"),
      ],
    ),
  )
  assert_true(decoded.error is None)
  assert_eq(decoded.output, plain)
  inspect(decoder.ignored_chunks(), content="6")
  inspect(decoder.palette().length(), content="0")
  // A truecolor image keeps a suggested palette.
  let decoder = Decoder()
  let rgb = png_of(
    [
      chunk("IHDR", ihdr_data(1, 1, 8, 2)),
      chunk("PLTE", b"\x01\x02\x03"),
      ..idat_chunks(@zlib.compress(b"\x00\x01\x02\x03"), 100),
      chunk("IEND", b""),
    ],
  )
  assert_true(run(decoder, rgb).error is None)
  inspect(decoder.palette().length(), content="3")
}

///|
test "the end of the image: trailing data, until=EndOfMember, end" {
  let (png, raw) = image(3, 3, 8, 0)
  let followed = Bytes::from_array([..png, ..b"more"])
  let trailing = run(Decoder(), followed)
  debug_inspect(trailing.error.map(e => e.0), content="Some(TrailingData)")
  inspect(trailing.consumed, content="\{png.length()}")
  assert_eq(trailing.output, raw.rows)
  // Byte by byte, the trailing byte still comes alone.
  let one = run(Decoder(), followed, chunk=1)
  inspect(one.consumed, content="\{png.length()}")
  // Stopping at IEND, nothing after it is consumed.
  for chunk in [1, 1 << 20] {
    let stopped = run(Decoder(until=EndOfMember), followed, chunk~)
    assert_true(stopped.error is None)
    inspect(stopped.consumed, content="\{png.length()}")
    assert_eq(stopped.output, raw.rows)
  }
  // Without end, a whole image waits for it.
  let decoder = Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = png[:]
  for ;; {
    let status = decoder.step(rest, out.mut_view(), end=false)
    rest = rest[decoder.last_consumed():]
    if status is NeedMoreInput && rest.length() == 0 {
      break
    }
  }
  debug_inspect(decoder.step(b"", out.mut_view(), end=true), content="Done")
  // Every proper prefix is Truncated.
  for cut in 0..<png.length() {
    let cut_run = run(Decoder(), png[:cut].to_owned())
    if !(cut_run.error is Some((Truncated, _))) {
      fail("the first \{cut} bytes: \{@debug.to_string(cut_run.error)}")
    }
  }
}

///|
test "reset: a used decoder decodes as a fresh one" {
  let (a, _) = image(9, 5, 16, 6, interlaced=true)
  let (b, raw) = image(4, 3, 2, 3)
  let decoder = Decoder()
  let _ = run(decoder, a[:a.length() / 2].to_owned())
  decoder.reset()
  let again = run(decoder, b)
  assert_true(again.error is None)
  assert_eq(again.output, raw.rows)
  // And after an error.
  let _ = run(decoder, b"\x89PNX")
  decoder.reset()
  assert_eq(run(decoder, b).output, raw.rows)
}

///|
/// Decodes `input` through the image contract alone, and describes each
/// answer with what the contract's accessors report.
fn through_contract(
  decoder : &@codec_image.Decode,
  input : Bytes,
) -> String raise {
  let out = FixedArray::make(1 << 16, b'\x00')
  let lines = []
  let mut rest = input[:]
  for ;; {
    let status = decoder.step(rest, out.mut_view(), end=true)
    rest = rest[decoder.last_consumed():]
    match status {
      Header => lines.push("header \{decoder.width()}x\{decoder.height()}")
      Frame =>
        lines.push(
          "frame \{decoder.frame_x()},\{decoder.frame_y()} \{decoder.frame_width()}x\{decoder.frame_height()}, room \{decoder.room_needed()}",
        )
      Rows =>
        lines.push(
          "pass \{decoder.pass()} at \{decoder.pass_x()},\{decoder.pass_y()} by \{decoder.pass_dx()},\{decoder.pass_dy()}: \{decoder.rows_count()} rows from \{decoder.rows_first()} of \{decoder.row_bytes()}, \{decoder.last_produced()} bytes",
        )
      Done => {
        lines.push("done, \{decoder.memory_usage()} bytes held")
        break
      }
      other => lines.push(@debug.to_string(other))
    }
  }
  decoder.reset()
  inspect(decoder.memory_usage(), content="47360")
  lines.join("\n")
}

///|
test "the decoder is a gaato/codec_image decoder" {
  let (png, _) = image(3, 2, 8, 2, interlaced=true)
  inspect(
    through_contract(Decoder(), png),
    content=(
      #|header 3x2
      #|frame 0,0 3x2, room 3
      #|pass 0 at 0,0 by 8,8: 1 rows from 0 of 3, 3 bytes
      #|pass 3 at 2,0 by 4,4: 1 rows from 0 of 3, 3 bytes
      #|pass 5 at 1,0 by 2,2: 1 rows from 0 of 3, 3 bytes
      #|pass 6 at 0,1 by 1,2: 1 rows from 0 of 9, 9 bytes
      #|FrameEnd
      #|done, 47380 bytes held
    ),
  )
}

///|
test "color_type: each of table 11" {
  let seen = []
  for format in formats {
    let (color_type, bit_depth) = format
    let decoder = Decoder()
    let _ = run(decoder, image(1, 1, bit_depth, color_type).0)
    seen.push("\{color_type} \{@debug.to_string(decoder.color_type())}")
  }
  inspect(
    seen.join(", "),
    content="0 Grayscale, 0 Grayscale, 0 Grayscale, 0 Grayscale, 0 Grayscale, 2 Truecolor, 2 Truecolor, 3 IndexedColor, 3 IndexedColor, 3 IndexedColor, 3 IndexedColor, 4 GrayscaleAlpha, 4 GrayscaleAlpha, 6 TruecolorAlpha, 6 TruecolorAlpha",
  )
}

///|
test "a truecolor image's PLTE of a wrong length is left out" {
  let decoder = Decoder()
  let rgb = png_of(
    [
      chunk("IHDR", ihdr_data(1, 1, 8, 2)),
      chunk("PLTE", b"\x01\x02"),
      ..idat_chunks(@zlib.compress(b"\x00\x01\x02\x03"), 100),
      chunk("IEND", b""),
    ],
  )
  assert_true(run(decoder, rgb).error is None)
  inspect(decoder.palette().length(), content="0")
  inspect(decoder.ignored_chunks(), content="1")
}

///|
test "step_into writes what step writes, into a whole array" {
  for format in formats {
    let (color_type, bit_depth) = format
    for interlaced in [false, true] {
      let (png, raw) = image(11, 6, bit_depth, color_type, interlaced~)
      for room in [1, 40] {
        let decoder = Decoder()
        let rows = Buffer()
        let mut rest = png[:]
        for ;; {
          let out = FixedArray::make(room.max(decoder.room_needed()), b'\x00')
          let status = decoder.step_into(rest, out, end=true)
          rest = rest[decoder.last_consumed():]
          rows.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
          if status is Done {
            break
          }
        }
        assert_eq(rows.to_bytes(), raw.rows)
      }
    }
  }
}
