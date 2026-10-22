///|
/// A row of `samples`, packed at `depth` bits each as PNG packs them.
fn packed(samples : Array[Int32], depth : Int32) -> FixedArray[Byte] {
  let out = Buffer()
  if depth == 16 {
    for v in samples {
      out.write_byte((v >> 8).to_byte())
      out.write_byte(v.to_byte())
    }
  } else {
    let per_byte = 8 / depth
    let mut acc = 0
    for i, v in samples {
      acc = acc * (1 << depth) + v
      if i % per_byte == per_byte - 1 {
        out.write_byte(acc.to_byte())
        acc = 0
      }
    }
    let left = samples.length() % per_byte
    if left > 0 {
      out.write_byte((acc << (depth * (per_byte - left))).to_byte())
    }
  }
  FixedArray::from_array(out.to_bytes().to_array())
}

///|
/// `converter` over `row` of `pixels` pixels into a fresh array of `n`
/// bytes a pixel, by `method`.
fn converted(
  convert : (Converter, ArrayView[Byte], Int32, MutArrayView[Byte]) -> Unit,
  converter : Converter,
  row : FixedArray[Byte],
  pixels : Int32,
  n : Int32,
) -> Array[Int32] {
  let out = FixedArray::make(pixels * n, b'\xee')
  convert(converter, row[:], pixels, out.mut_view())
  out.iter().map(b => b.to_int()).to_array()
}

///|
test "rgba8: gray widened by repeating its bits, alpha from tRNS" {
  let row = packed([0, 1, 2, 3], 2)
  let gray = Converter(Grayscale, 2, transparency=Gray(2))
  debug_inspect(
    converted(Converter::rgba8, gray, row, 4, 4),
    content="[0, 0, 0, 255, 85, 85, 85, 255, 170, 170, 170, 0, 255, 255, 255, 255]",
  )
  // 1 and 4 bits.
  debug_inspect(
    converted(
      Converter::rgba8,
      Converter(Grayscale, 1),
      packed([1, 0, 1], 1),
      3,
      4,
    ),
    content="[255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255]",
  )
  debug_inspect(
    converted(
      Converter::rgba8,
      Converter(Grayscale, 4),
      packed([7, 15], 4),
      2,
      4,
    ),
    content="[119, 119, 119, 255, 255, 255, 255, 255]",
  )
  // 16 bits rounded to 8: 0x8080 is 128.5 / 255 of the way, 0x807f below.
  debug_inspect(
    converted(
      Converter::rgba8,
      Converter(Grayscale, 16),
      packed([0x8080, 0x807F, 0xFFFF], 16),
      3,
      4,
    ),
    content="[128, 128, 128, 255, 128, 128, 128, 255, 255, 255, 255, 255]",
  )
}

///|
test "rgba8: truecolor, alpha channels, a key color" {
  let rgb = Converter(Truecolor, 8, transparency=Rgb(1, 2, 3))
  debug_inspect(
    converted(Converter::rgba8, rgb, packed([1, 2, 3, 1, 2, 4], 8), 2, 4),
    content="[1, 2, 3, 0, 1, 2, 4, 255]",
  )
  let ga = Converter(GrayscaleAlpha, 16)
  debug_inspect(
    converted(Converter::rgba8, ga, packed([0xFFFF, 0x0100], 16), 1, 4),
    content="[255, 255, 255, 1]",
  )
  let rgba = Converter(TruecolorAlpha, 8)
  debug_inspect(
    converted(Converter::rgba8, rgba, packed([9, 8, 7, 6], 8), 1, 4),
    content="[9, 8, 7, 6]",
  )
}

///|
test "palette: entries with tRNS's alpha, indices past the palette opaque black" {
  let palette : FixedArray[Byte] = [
    b'\x10', b'\x20', b'\x30', b'\x40', b'\x50', b'\x60',
  ]
  let indexed = Converter(
    IndexedColor,
    4,
    palette=palette[:],
    transparency=Alpha(palette[:1]),
  )
  let row = packed([0, 1, 2, 15], 4)
  debug_inspect(
    converted(Converter::rgba8, indexed, row, 4, 4),
    content="[16, 32, 48, 16, 64, 80, 96, 255, 0, 0, 0, 255, 0, 0, 0, 255]",
  )
  debug_inspect(
    converted(Converter::rgba16, indexed, row, 1, 8),
    content="[16, 16, 32, 32, 48, 48, 16, 16]",
  )
  debug_inspect(indexed.expanded_channels(), content="4")
  debug_inspect(
    converted(Converter::expanded, indexed, row, 4, 4),
    content="[16, 32, 48, 16, 64, 80, 96, 255, 0, 0, 0, 255, 0, 0, 0, 255]",
  )
  let plain = Converter(IndexedColor, 8, palette=palette[:])
  debug_inspect(plain.expanded_channels(), content="3")
  debug_inspect(
    converted(Converter::expanded, plain, packed([1, 200], 8), 2, 3),
    content="[64, 80, 96, 0, 0, 0]",
  )
}

///|
test "rgba16: samples widened to 16 bits by repeating their bits, big-endian" {
  debug_inspect(
    converted(
      Converter::rgba16,
      Converter(Grayscale, 2, transparency=Gray(1)),
      packed([1, 2], 2),
      2,
      8,
    ),
    content="[85, 85, 85, 85, 85, 85, 0, 0, 170, 170, 170, 170, 170, 170, 255, 255]",
  )
  debug_inspect(
    converted(
      Converter::rgba16,
      Converter(Truecolor, 16, transparency=Rgb(1, 2, 3)),
      packed([1, 2, 3], 16),
      1,
      8,
    ),
    content="[0, 1, 0, 2, 0, 3, 0, 0]",
  )
  debug_inspect(
    converted(
      Converter::rgba16,
      Converter(TruecolorAlpha, 8),
      packed([1, 2, 3, 4], 8),
      1,
      8,
    ),
    content="[1, 1, 2, 2, 3, 3, 4, 4]",
  )
}

///|
test "expanded: the png crate's EXPAND layouts" {
  let gray = Converter(Grayscale, 4, transparency=Gray(3))
  debug_inspect(
    (gray.expanded_channels(), gray.expanded_depth()),
    content="(2, 8)",
  )
  debug_inspect(
    converted(Converter::expanded, gray, packed([3, 4], 4), 2, 2),
    content="[51, 0, 68, 255]",
  )
  let deep = Converter(Grayscale, 16, transparency=Gray(5))
  debug_inspect(
    (deep.expanded_channels(), deep.expanded_depth()),
    content="(2, 16)",
  )
  debug_inspect(
    converted(Converter::expanded, deep, packed([5, 6], 16), 2, 4),
    content="[0, 5, 0, 0, 0, 6, 255, 255]",
  )
  let rgb = Converter(Truecolor, 8)
  debug_inspect(rgb.expanded_channels(), content="3")
  let rgba = Converter(TruecolorAlpha, 16)
  debug_inspect(
    (rgba.expanded_channels(), rgba.expanded_depth()),
    content="(4, 16)",
  )
  let ga = Converter(GrayscaleAlpha, 8)
  debug_inspect(
    converted(Converter::expanded, ga, packed([7, 9], 8), 1, 2),
    content="[7, 9]",
  )
}

///|
/// The pass rows of an image of `samples` (`channels` a pixel, `depth`
/// bits each, `width` x `height`), in Adam7's order, packed: what an
/// interlaced image's IDAT holds before filtering, a filter type of 0 a row.
fn adam7_filtered(
  samples : Array[Int32],
  width : Int32,
  height : Int32,
  channels : Int32,
  depth : Int32,
) -> Bytes {
  let out = Buffer()
  for pass in 0..<7 {
    let columns = adam7_columns(pass, width)
    let rows = adam7_rows(pass, height)
    if columns == 0 || rows == 0 {
      continue
    }
    for r in 0..<rows {
      let y = adam7_y(pass) + r * adam7_dy(pass)
      let row = []
      for i in 0..<columns {
        let x = adam7_x(pass) + i * adam7_dx(pass)
        for c in 0..<channels {
          row.push(samples[(y * width + x) * channels + c])
        }
      }
      out.write_byte(b'\x00')
      out.write_bytes(Bytes::from_array(packed(row, depth)[:]))
    }
  }
  out.to_bytes()
}

///|
test "decode: interlaced and not, the same image, every depth, every size up to 9 x 9" {
  for format in formats {
    let (color_type, depth) = format
    let channels = @rules.channels(color_type)
    for width in 1..<=9 {
      for height in 1..<=9 {
        let noise = Noise::{
          state: (width * 16 + height).reinterpret_as_uint(),
        }
        let top = if color_type == 3 { 1 << depth.min(4) } else { 1 << depth }
        let samples = Array::makei(width * height * channels, _ => {
          (noise.byte().to_int() * 256 + noise.byte().to_int()) % top
        })
        let plain = Buffer()
        for y in 0..<height {
          plain.write_byte(b'\x00')
          let row = samples[y * width * channels:(y + 1) * width * channels].to_owned()
          plain.write_bytes(Bytes::from_array(packed(row, depth)[:]))
        }
        let make = (data : Bytes, interlace : Int32) => {
          let chunks = [
            chunk(
              "IHDR",
              ihdr_data(
                width.reinterpret_as_uint(),
                height.reinterpret_as_uint(),
                depth,
                color_type,
                interlace~,
              ),
            ),
          ]
          if color_type == 3 {
            chunks.push(
              chunk("PLTE", Bytes::makei(3 << depth, i => i.to_byte())),
            )
          }
          chunks.append(idat_chunks(@zlib.compress(data), 1 << 20))
          chunks.push(chunk("IEND", b""))
          png_of(chunks)
        }
        let a = decode(make(plain.to_bytes(), 0))
        let b = decode(
          make(adam7_filtered(samples, width, height, channels, depth), 1),
        )
        if a.pixels != b.pixels {
          fail("\{color_type}/\{depth} \{width}x\{height}: other pixels")
        }
        assert_eq(a.row_bytes * height, a.pixels.length())
      }
    }
  }
}

///|
test "decode: only checked rows, max_output before anything is allocated, is_signature" {
  let (png, raw) = image(5, 4, 8, 2)
  let whole = decode(png)
  assert_eq(Bytes::from_array(whole.pixels[:]), raw.rows)
  debug_inspect(
    (whole.width, whole.height, whole.row_bytes),
    content="(5, 4, 15)",
  )
  debug_inspect(whole.row(1).length(), content="15")
  // 60 bytes of rows, against 59 and 60.
  let over = try decode(png, max_output=59) catch {
    CodecError(LimitExceeded(limit), _) => Some(limit)
    _ => None
  } noraise {
    _ => None
  }
  debug_inspect(
    over,
    content="Some({ resource: Output, needed: Some(60), limit: 59 })",
  )
  assert_eq(decode(png, max_output=60).pixels.length(), 60)
  // A CRC wrong after the rows: no image.
  let broken = png.to_array()
  let at = broken.length() - 12 - 4
  broken[at] = broken[at] ^ b'\x01'
  let kind = try decode(Bytes::from_array(broken)) catch {
    CodecError(kind, _) => Some(kind)
  } noraise {
    _ => None
  }
  debug_inspect(kind, content="Some(ChecksumMismatch)")
  assert_true(is_signature(png[:]))
  assert_true(is_signature(png[:8]))
  assert_false(is_signature(png[:7]))
  assert_false(is_signature(b"GIF89a\x00\x00"[:]))
  // An APNG gives its default image.
  let (z0, r0) = frame_data(8, 6, seed=1)
  let (z1, _) = frame_data(8, 6, seed=2)
  let animated = apng_of(
    [actl(1), ..idat_chunks(z0, 100), fctl(0, 8, 6), ..fdats(1, z1)],
  )
  assert_eq(Bytes::from_array(decode(animated).pixels[:]), r0)
  // Through the image's converter.
  let rgba = FixedArray::make(5 * 4, b'\x00')
  whole.converter.rgba8(whole.row(0), 5, rgba.mut_view())
  assert_eq(rgba[0], raw.rows[0])
  assert_eq(rgba[3], b'\xff')
}

///|
test "scatter: packed pixels go bit by bit, and the other bits stay" {
  let into = FixedArray::make(2, b'\xff')
  // Two 2-bit pixels, 0 and 1, to columns 1 and 5.
  scatter(packed([0, 1], 2)[:], 2, 2, 1, 4, into.mut_view())
  debug_inspect(
    into.iter().map(b => b.to_int()).to_array(),
    content="[207, 223]",
  )
}

///|
test "decode: an image larger than an array holds is refused at its header" {
  let huge = png_of([chunk("IHDR", ihdr_data(65535, 65535, 8, 0))])
  let refused = try decode(huge) catch {
    CodecError(LimitExceeded(limit), _) => Some(limit)
    _ => None
  } noraise {
    _ => None
  }
  debug_inspect(
    refused,
    content="Some({ resource: Output, needed: Some(4294836225), limit: 2147483647 })",
  )
}
