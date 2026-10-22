///|
/// A 2 x 1 image of `color_type` and `bit_depth`, with `before` after IHDR
/// (and PLTE, for indexed-color), and `after` after its image data.
fn with_chunks(
  color_type : Int32,
  bit_depth : Int32,
  before : Array[Array[Byte]],
  after~ : Array[Array[Byte]] = [],
  palette~ : Int32 = 4,
) -> Bytes {
  let bits = @rules.channels(color_type) * bit_depth
  let raw = raw_image(2, 1, bits)
  let chunks = [chunk("IHDR", ihdr_data(2, 1, bit_depth, color_type))]
  if color_type == 3 {
    chunks.push(chunk("PLTE", Bytes::makei(3 * palette, i => i.to_byte())))
  }
  chunks.append(before)
  chunks.append(idat_chunks(@zlib.compress(raw.filtered), 100))
  chunks.append(after)
  chunks.push(chunk("IEND", b""))
  png_of(chunks)
}

///|
/// Decodes `png` whole and returns the decoder.
fn decoded(png : Bytes, report? : Array[String]) -> Decoder raise {
  let decoder = match report {
    Some(report) => Decoder(report~)
    None => Decoder()
  }
  let run = run(decoder, png)
  if run.error is Some((kind, message)) {
    fail("\{@debug.to_string(kind)}: \{message}")
  }
  decoder
}

///|
fn be16s(values : Array[Int32]) -> Bytes {
  Bytes::from_array(
    values
    .map(v => [(v >> 8).to_byte(), v.to_byte()])
    .fold(init=[], (a, b) => [..a, ..b]),
  )
}

///|
fn be32s(values : Array[UInt32]) -> Bytes {
  Bytes::from_array(values.map(be32).fold(init=[], (a, b) => [..a, ..b]))
}

///|
test "tRNS: a gray level, a color, the palette's alpha; the bits above the bit depth left out" {
  let gray = decoded(with_chunks(0, 8, [chunk("tRNS", be16s([0x0105]))]))
  debug_inspect(gray.transparency(), content="Some(Gray(5))")
  inspect(gray.ignored_chunks(), content="0")
  // As in WPT's trns-high-bits-set.png: ffff 0000 0000 on 8-bit samples is
  // the color 255, 0, 0.
  let rgb = decoded(with_chunks(2, 8, [chunk("tRNS", be16s([0xFFFF, 0, 0]))]))
  debug_inspect(rgb.transparency(), content="Some(Rgb(255, 0, 0))")
  let deep = decoded(with_chunks(0, 16, [chunk("tRNS", be16s([0x1234]))]))
  debug_inspect(deep.transparency(), content="Some(Gray(4660))")
  let low = decoded(with_chunks(0, 2, [chunk("tRNS", be16s([7]))]))
  debug_inspect(low.transparency(), content="Some(Gray(3))")
  let indexed = decoded(with_chunks(3, 8, [chunk("tRNS", b"\x00\x80")]))
  debug_inspect(
    indexed.transparency(),
    content="Some(Alpha(<ArrayView: [0x00, 0x80]>))",
  )
  // Left out: more alpha than entries, none, a level of the wrong length,
  // tRNS with an alpha channel, tRNS before PLTE.
  for
    png in [
      with_chunks(3, 8, [chunk("tRNS", b"\x00\x01\x02\x03\x04")]),
      with_chunks(3, 8, [chunk("tRNS", b"")]),
      with_chunks(0, 8, [chunk("tRNS", b"\x00\x01\x02")]),
      with_chunks(2, 8, [chunk("tRNS", be16s([1, 2]))]),
      with_chunks(4, 8, [chunk("tRNS", be16s([1]))]),
      with_chunks(6, 8, [chunk("tRNS", be16s([1, 2, 3]))]),
      png_of(
        [
          chunk("IHDR", ihdr_data(2, 1, 8, 3)),
          chunk("tRNS", b"\x00"),
          chunk("PLTE", Bytes::make(12, b'\x00')),
          ..idat_chunks(@zlib.compress(b"\x00\x00\x00"), 100),
          chunk("IEND", b""),
        ],
      ),
    ] {
    let decoder = decoded(png)
    debug_inspect(decoder.transparency(), content="None")
    inspect(decoder.ignored_chunks(), content="1")
  }
}

///|
test "sBIT, gAMA, cHRM, sRGB, cICP, mDCV, cLLI, pHYs and bKGD, valid" {
  let chrm : Array[UInt32] = [
    31270, 32900, 64000, 33000, 30000, 60000, 15000, 6000,
  ]
  let decoder = decoded(
    with_chunks(2, 8, [
      chunk("sBIT", b"\x05\x06\x05"),
      chunk("gAMA", be32s([45455])),
      chunk("cHRM", be32s(chrm)),
      chunk("sRGB", b"\x00"),
      chunk("cICP", b"\x09\x10\x00\x01"),
      chunk(
        "mDCV",
        Bytes::from_array(
          [
            ..be16s([35400, 14600, 8500, 39850, 6550, 2300, 15635, 16450]),
            ..be32s([10000000, 1]),
          ],
        ),
      ),
      chunk("cLLI", be32s([10000000, 4000000])),
      chunk("pHYs", Bytes::from_array([..be32s([2835, 2835]), b'\x01'])),
      chunk("bKGD", be16s([255, 128, 0])),
    ]),
  )
  inspect(decoder.ignored_chunks(), content="0")
  debug_inspect(
    decoder.significant_bits().to_owned(),
    content="[0x05, 0x06, 0x05]",
  )
  debug_inspect(decoder.gamma(), content="Some(45455)")
  debug_inspect(
    decoder.chromaticities(),
    content=(
      #|Some(
      #|  {
      #|    white_x: 31270,
      #|    white_y: 32900,
      #|    red_x: 64000,
      #|    red_y: 33000,
      #|    green_x: 30000,
      #|    green_y: 60000,
      #|    blue_x: 15000,
      #|    blue_y: 6000,
      #|  },
      #|)
    ),
  )
  debug_inspect(decoder.srgb_intent(), content="Some(0)")
  debug_inspect(
    decoder.coding_points(),
    content=(
      #|Some(
      #|  {
      #|    color_primaries: 9,
      #|    transfer_function: 16,
      #|    matrix_coefficients: 0,
      #|    full_range: true,
      #|  },
      #|)
    ),
  )
  debug_inspect(
    decoder.mastering_display(),
    content=(
      #|Some(
      #|  {
      #|    red_x: 35400,
      #|    red_y: 14600,
      #|    green_x: 8500,
      #|    green_y: 39850,
      #|    blue_x: 6550,
      #|    blue_y: 2300,
      #|    white_x: 15635,
      #|    white_y: 16450,
      #|    max_luminance: 10000000,
      #|    min_luminance: 1,
      #|  },
      #|)
    ),
  )
  debug_inspect(
    decoder.light_level(),
    content="Some({ max_content: 10000000, max_frame_average: 4000000 })",
  )
  debug_inspect(
    decoder.physical_size(),
    content="Some({ x: 2835, y: 2835, per_meter: true })",
  )
  debug_inspect(decoder.background(), content="Some(Rgb(255, 128, 0))")
  // A fresh decoder knows none of them.
  decoder.reset()
  debug_inspect(decoder.gamma(), content="None")
  inspect(decoder.significant_bits().length(), content="0")
}

///|
test "fixed-length chunks with values out of range, or the wrong length, are left out" {
  let cases : Array[(Int32, Int32, Array[Byte])] = [
    (0, 8, chunk("sBIT", b"\x00")),
    (0, 8, chunk("sBIT", b"\x09")),
    (0, 8, chunk("sBIT", b"\x08\x08")),
    (0, 8, chunk("gAMA", be32s([0]))),
    (0, 8, chunk("gAMA", be32s([0x80000000]))),
    (0, 8, chunk("gAMA", b"\x00\x01")),
    (0, 8, chunk("cHRM", be32s([0x80000000, 1, 1, 1, 1, 1, 1, 1]))),
    (0, 8, chunk("cHRM", be32s([1, 1, 1]))),
    (0, 8, chunk("sRGB", b"\x04")),
    (0, 8, chunk("sRGB", b"")),
    (2, 8, chunk("cICP", b"\x01\x0d\x01\x01")),
    (2, 8, chunk("cICP", b"\x01\x0d\x00\x02")),
    (2, 8, chunk("cICP", b"\x01\x0d\x00")),
    (2, 8, chunk("mDCV", Bytes::make(23, b'\x00'))),
    (2, 8, chunk("cLLI", Bytes::make(9, b'\x00'))),
    (0, 8, chunk("pHYs", Bytes::make(9, b'\x02'))),
    (0, 8, chunk("pHYs", Bytes::make(8, b'\x00'))),
    (3, 8, chunk("bKGD", b"\x04")),
    (0, 4, chunk("bKGD", be16s([16]))),
    (2, 8, chunk("bKGD", be16s([0, 256, 0]))),
    (2, 8, chunk("bKGD", be16s([0, 0]))),
    // Longer than any fixed-length chunk.
    (2, 8, chunk("cHRM", Bytes::make(300, b'\x00'))),
  ]
  for case in cases {
    let (color_type, bit_depth, bad) = case
    let decoder = decoded(with_chunks(color_type, bit_depth, [bad]))
    if decoder.ignored_chunks() != 1 {
      fail(
        "\{@debug.to_string(bad[4:8])}: \{decoder.ignored_chunks()} left out",
      )
    }
    if decoder.gamma() is Some(_) ||
      decoder.chromaticities() is Some(_) ||
      decoder.srgb_intent() is Some(_) ||
      decoder.coding_points() is Some(_) ||
      decoder.mastering_display() is Some(_) ||
      decoder.light_level() is Some(_) ||
      decoder.physical_size() is Some(_) ||
      decoder.background() is Some(_) ||
      decoder.significant_bits().length() > 0 {
      fail("\{@debug.to_string(bad[4:8])} was read")
    }
  }
  // sBIT of an indexed-color image: three values up to 8, before PLTE.
  let indexed = (sbit : Bytes) => {
    png_of(
      [
        chunk("IHDR", ihdr_data(2, 1, 4, 3)),
        chunk("sBIT", sbit),
        chunk("PLTE", Bytes::make(12, b'\x00')),
        ..idat_chunks(@zlib.compress(b"\x00\x00"), 100),
        chunk("IEND", b""),
      ],
    )
  }
  let fine = decoded(indexed(b"\x08\x05\x08"))
  debug_inspect(
    fine.significant_bits().to_owned(),
    content="[0x08, 0x05, 0x08]",
  )
  let wrong = decoded(indexed(b"\x08\x09\x08"))
  inspect(wrong.significant_bits().length(), content="0")
  inspect(wrong.ignored_chunks(), content="1")
  // Within the bit depth, at its edge.
  let edge = decoded(with_chunks(0, 4, [chunk("bKGD", be16s([15]))]))
  debug_inspect(edge.background(), content="Some(Gray(15))")
  let index = decoded(with_chunks(3, 8, [chunk("bKGD", b"\x03")]))
  debug_inspect(index.background(), content="Some(Index(3))")
  // A copy left out does not stop a valid one after it.
  let second = decoded(
    with_chunks(0, 8, [
      chunk("gAMA", be32s([0])),
      chunk("gAMA", be32s([100000])),
      chunk("gAMA", be32s([50000])),
    ]),
  )
  debug_inspect(second.gamma(), content="Some(100000)")
  inspect(second.ignored_chunks(), content="2")
  // A bad CRC leaves the chunk out too.
  let crc = decoded(
    with_chunks(0, 8, [chunk("gAMA", be32s([100000]), bad_crc=1)]),
  )
  debug_inspect(crc.gamma(), content="None")
  inspect(crc.ignored_chunks(), content="1")
}

///|
/// `bytes` with printable ASCII as it is and the rest as `\xNN`.
fn escaped(bytes : Bytes) -> String {
  let out = StringBuilder()
  for b in bytes {
    let c = b.to_int()
    if c >= 0x20 && c < 0x7F && c != 0x5C {
      out.write_char(c.unsafe_to_char())
    } else {
      let hex = "0123456789abcdef"
      out.write_string("\\x")
      out.write_char(hex[c >> 4].unsafe_to_char())
      out.write_char(hex[c & 15].unsafe_to_char())
    }
  }
  out.to_string()
}

///|
/// The `Metadata` blocks of a run of `decoder` over `png` in chunks of
/// `chunk` bytes with `room` bytes a step, as type and text.
fn blocks(
  decoder : Decoder,
  png : Bytes,
  chunk~ : Int32 = 1 << 20,
  room~ : Int32 = 1 << 16,
) -> Array[String] raise {
  let found = []
  let mut pos = 0
  let mut pending = png[0:0]
  for ;; {
    if pending.length() == 0 && pos < png.length() {
      let next = (pos + chunk).min(png.length())
      pending = png[pos:next]
      pos = next
    }
    let out = FixedArray::make(room.max(decoder.room_needed()), b'\x00')
    let status = decoder.step(pending, out.mut_view(), end=pos == png.length())
    pending = pending[decoder.last_consumed():]
    match status {
      Metadata => {
        let bytes = Bytes::from_array(out[:decoder.last_produced()])
        found.push("\{decoder.metadata_type()} b\"\{escaped(bytes)}\"")
      }
      Done => return found
      _ => ()
    }
  }
}

///|
test "report: tEXt as it is, zTXt and iCCP inflated, iTXt either way, unknown chunks, after the image data too" {
  let ztxt = Bytes::from_array(
    [..b"Comment\x00\x00", ..@zlib.compress(b"hello, hello, hello")],
  )
  let iccp = Bytes::from_array(
    [..b"sRGB profile\x00\x00", ..@zlib.compress(Bytes::make(40, b'\x07'))],
  )
  let itxt_packed = Bytes::from_array(
    [
      ..b"Title\x00\x01\x00ja\x00\xe9\xa1\x8c\x00",
      ..@zlib.compress(b"\xe7\x8c\xab"),
    ],
  )
  let itxt_plain = b"Title\x00\x00\x00en\x00Title\x00cat"
  let png = with_chunks(
    0,
    8,
    [
      chunk("iCCP", iccp),
      chunk("tEXt", b"Author\x00someone"),
      chunk("abCd", b"\x01\x02"),
      chunk("gAMA", be32s([45455])),
    ],
    after=[
      chunk("zTXt", ztxt),
      chunk("iTXt", itxt_packed),
      chunk("iTXt", itxt_plain),
      chunk("tIME", b"\x07\xea\x0a\x16\x0c\x00\x00"),
    ],
  )
  let report = ["iCCP", "tEXt", "zTXt", "iTXt", "abCd", "gAMA", "tIME"]
  let found = blocks(Decoder(report~), png)
  inspect(
    found.join("\n"),
    content=(
      #|iCCP b"sRGB profile\x00\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07\x07"
      #|tEXt b"Author\x00someone"
      #|abCd b"\x01\x02"
      #|gAMA b"\x00\x00\xb1\x8f"
      #|zTXt b"Comment\x00hello, hello, hello"
      #|iTXt b"Title\x00\x00\x00ja\x00\xe9\xa1\x8c\x00\xe7\x8c\xab"
      #|iTXt b"Title\x00\x00\x00en\x00Title\x00cat"
      #|tIME b"\x07\xea\x0a\x16\x0c\x00\x00"
    ),
  )
  // The same under any split of input and output.
  for split in [(1, 1), (3, 5), (17, 100)] {
    let again = blocks(Decoder(report~), png, chunk=split.0, room=split.1)
    assert_eq(again, found)
  }
  // Without being asked, nothing is reported; gAMA is read either way.
  assert_eq(blocks(Decoder(), png), [])
  let only = Decoder(report=["tEXt", "IDAT", "x", "tEXtt"])
  inspect(blocks(only, png).length(), content="1")
  debug_inspect(only.gamma(), content="Some(45455)")
}

///|
test "report: chunks that are not what their type says are left out and counted" {
  let packed = @zlib.compress(b"some text")
  let cases = [
    // A bad CRC.
    chunk("tEXt", b"a\x00b", bad_crc=1),
    // zTXt: no keyword, a keyword of 80 bytes, another method, a broken or
    // unfinished zlib stream.
    chunk("zTXt", Bytes::from_array([b'\x00', b'\x00', ..packed])),
    chunk(
      "zTXt",
      Bytes::from_array([..Bytes::make(80, b'k'), b'\x00', b'\x00', ..packed]),
    ),
    chunk("zTXt", Bytes::from_array([..b"k\x00\x01", ..packed])),
    chunk("zTXt", b"k\x00\x00\x78\x9c\xff\xff"),
    chunk("zTXt", Bytes::from_array([..b"k\x00\x00", ..packed[:6]])),
    chunk("zTXt", b"k\x00"),
    // iCCP and iTXt the same; iTXt with a flag of 2, a method of 1.
    chunk("iCCP", Bytes::from_array([..b"p\x00\x01", ..packed])),
    chunk("iTXt", Bytes::from_array([..b"k\x00\x02\x00\x00\x00", ..packed])),
    chunk("iTXt", Bytes::from_array([..b"k\x00\x01\x01\x00\x00", ..packed])),
    chunk("iTXt", b"k\x00\x00\x00en"),
  ]
  for bad in cases {
    let decoder = Decoder(report=["tEXt", "zTXt", "iCCP", "iTXt"])
    let found = blocks(decoder, with_chunks(0, 8, [], after=[bad]))
    if found.length() != 0 || decoder.ignored_chunks() != 1 {
      fail(
        "\{@debug.to_string(bad[4:8])}: \{found.length()} reported, \{decoder.ignored_chunks()} left out",
      )
    }
  }
  // A keyword of 79 bytes is fine; bytes after the zlib stream are dropped.
  let decoder = Decoder(report=["zTXt"])
  let found = blocks(
    decoder,
    with_chunks(0, 8, [], after=[
      chunk(
        "zTXt",
        Bytes::from_array(
          [..Bytes::make(79, b'k'), b'\x00', b'\x00', ..packed, b'\x01'],
        ),
      ),
    ]),
  )
  inspect(found.length(), content="1")
  inspect(decoder.ignored_chunks(), content="0")
}

///|
test "report: max_chunk_bytes bounds a block, as it comes and as it inflates" {
  let text = Bytes::make(100, b't')
  let raw = with_chunks(0, 8, [
    chunk("tEXt", Bytes::from_array([..b"k\x00", ..text])),
  ])
  // 102 bytes of chunk, against 101 and 102.
  let refused = run(Decoder(report=["tEXt"], max_chunk_bytes=101), raw).error catch {
      _ => None
    }
  debug_inspect(
    refused.map(e => e.0),
    content="Some(LimitExceeded({ resource: Memory, needed: Some(102), limit: 101 }))",
  )
  inspect(
    blocks(Decoder(report=["tEXt"], max_chunk_bytes=102), raw).length(),
    content="1",
  )
  // Inflated to 2 + 100 bytes, against 101 and 102.
  let packed = with_chunks(0, 8, [
    chunk("zTXt", Bytes::from_array([..b"k\x00\x00", ..@zlib.compress(text)])),
  ])
  let bomb = run(Decoder(report=["zTXt"], max_chunk_bytes=101), packed).error catch {
      _ => None
    }
  debug_inspect(
    bomb.map(e => e.0),
    content="Some(LimitExceeded({ resource: Memory, needed: None, limit: 101 }))",
  )
  inspect(
    blocks(Decoder(report=["zTXt"], max_chunk_bytes=102), packed).length(),
    content="1",
  )
  // Unasked, the same chunks are only skipped.
  assert_true(run(Decoder(max_chunk_bytes=1), packed).error is None)
}

///|
test "report: a block waits for room, and memory counts it and the second zlib decoder" {
  let png = with_chunks(0, 8, [chunk("tEXt", b"Author\x00someone")])
  let decoder = Decoder(report=["tEXt"])
  inspect(decoder.memory_usage(), content="47360")
  let out = FixedArray::make(4, b'\x00')
  let mut rest = png[:]
  for ;; {
    let status = decoder.step(rest, out.mut_view(), end=true)
    rest = rest[decoder.last_consumed():]
    if status is NeedMoreOutput {
      break
    }
  }
  // The block is the chunk's 14 bytes, held until handed out.
  inspect(decoder.room_needed(), content="14")
  // With the image's two rows of 1 + 2 bytes.
  inspect(decoder.memory_usage(), content="47380")
  let room = FixedArray::make(14, b'\x00')
  debug_inspect(
    decoder.step(rest, room.mut_view(), end=true),
    content="Metadata",
  )
  inspect(decoder.memory_usage(), content="47366")
  // Asking for a compressed type adds a zlib decoder.
  inspect(Decoder(report=["zTXt"]).memory_usage(), content="93952")
}

///|
test "report: step_into hands out blocks too, and a block grows past 256 bytes as it inflates" {
  let text = Bytes::makei(1000, i => (i % 26 + 97).to_byte())
  let png = with_chunks(0, 8, [
    chunk("zTXt", Bytes::from_array([..b"k\x00\x00", ..@zlib.compress(text)])),
  ])
  let decoder = Decoder(report=["zTXt"])
  let mut rest = png[:]
  let mut found = Bytes::make(0, b'\x00')
  for ;; {
    let out = FixedArray::make(decoder.room_needed().max(16), b'\x00')
    let status = decoder.step_into(rest, out, end=true)
    rest = rest[decoder.last_consumed():]
    if status is Metadata {
      found = Bytes::from_array(out[:decoder.last_produced()])
    }
    if status is Done {
      break
    }
  }
  assert_eq(found, Bytes::from_array([..b"k\x00", ..text]))
}
