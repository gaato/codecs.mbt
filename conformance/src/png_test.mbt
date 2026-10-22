// gaato/png over PngSuite (png_vectors_test.mbt): every image against
// pypng's samples and typst's decode_png, and under the harness's checks
// through the image adapter.

///|
/// A PngSuite image, and what pypng makes of it: `ok <w>x<h> <sha256>` of
/// its samples, or `error <exception>`.
struct PngVector {
  name : String
  data : String
  reference : String
}

///|
fn PngVector::input(self : PngVector) -> Bytes {
  @base64.decode(self.data, ignore_whitespace=true) catch {
    _ => abort("bad base64 in vector \{self.name}")
  }
}

///|
/// The kinds of error the broken images of PngSuite raise, by what their
/// names say is wrong: the signature (xs*, and xcr and xlf, whose line
/// endings were converted), a color type or bit depth IHDR does not allow
/// (xc*, xd0, xd3, xd9), IHDR's or IDAT's CRC (xhd, xcs), or no IDAT (xdt).
let broken_kinds : Map[String, String] = Map::from_array([
  ("xc1n0g08", "Corrupt"),
  ("xc9n2c08", "Corrupt"),
  ("xcrn0g04", "Corrupt"),
  ("xcsn0g01", "ChecksumMismatch"),
  ("xd0n2c08", "Corrupt"),
  ("xd3n2c08", "Corrupt"),
  ("xd9n2c08", "Corrupt"),
  ("xdtn0g01", "Corrupt"),
  ("xhdn0g08", "ChecksumMismatch"),
  ("xlfn0g04", "Corrupt"),
  ("xs1n0g01", "Corrupt"),
  ("xs2n0g01", "Corrupt"),
  ("xs4n0g01", "Corrupt"),
  ("xs7n0g01", "Corrupt"),
])

///|
/// An image as gaato/png gives it: its rows, pass by pass, and what the
/// decoder says about it.
struct Decoded {
  rows : Bytes
  width : Int32
  height : Int32
  bit_depth : Int32
  color_type : @png.ColorType
  interlaced : Bool
  palette : Bytes
}

///|
/// The samples a pixel of `color_type` has.
fn channels(color_type : @png.ColorType) -> Int32 {
  match color_type {
    Grayscale | IndexedColor => 1
    GrayscaleAlpha => 2
    Truecolor => 3
    TruecolorAlpha => 4
  }
}

///|
/// The row bytes of a pass `pixels` wide.
fn packed_bytes(pixels : Int32, bits : Int32) -> Int32 {
  (pixels * bits + 7) / 8
}

///|
/// Decodes `input` whole with a fresh decoder.
fn decode_png(input : Bytes) -> Decoded raise {
  let decoder = @png.Decoder()
  let rows = Buffer()
  let mut out = FixedArray::make(0, b'\x00')
  let mut rest = input[:]
  for ;; {
    if out.length() < decoder.room_needed() {
      out = FixedArray::make(decoder.room_needed() * 8, b'\x00')
    }
    let status = decoder.step(rest, out.mut_view(), end=true)
    rest = rest[decoder.last_consumed():]
    match status {
      Rows => rows.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
      Done => break
      _ => ()
    }
  }
  {
    rows: rows.to_bytes(),
    width: decoder.width(),
    height: decoder.height(),
    bit_depth: decoder.bit_depth(),
    color_type: decoder.color_type(),
    interlaced: decoder.interlaced(),
    palette: Bytes::from_array(decoder.palette()),
  }
}

///|
/// The image's samples, deinterlaced, sample by sample in rows: each
/// pass's pixels put where its lattice says, the samples of fewer than 8
/// bits unpacked to a byte each, 16-bit ones as two bytes. The passes'
/// lattices are Adam7's (8.2), written out here apart from the decoder.
fn samples(d : Decoded) -> FixedArray[Int32] {
  let n = channels(d.color_type)
  let bits = n * d.bit_depth
  let image = FixedArray::make(d.width * d.height * n, 0)
  let lattices = if d.interlaced {
    [
      (0, 0, 8, 8),
      (4, 0, 8, 8),
      (0, 4, 4, 8),
      (2, 0, 4, 4),
      (0, 2, 2, 4),
      (1, 0, 2, 2),
      (0, 1, 1, 2),
    ]
  } else {
    [(0, 0, 1, 1)]
  }
  let mut at = 0
  for lattice in lattices {
    let (x0, y0, dx, dy) = lattice
    if x0 >= d.width || y0 >= d.height {
      continue
    }
    let columns = (d.width - x0 + dx - 1) / dx
    let row_bytes = packed_bytes(columns, bits)
    for y = y0; y < d.height; y = y + dy {
      for i in 0..<columns {
        for c in 0..<n {
          let s = i * n + c
          let value = if d.bit_depth == 16 {
            (d.rows[at + 2 * s].to_int() << 8) | d.rows[at + 2 * s + 1].to_int()
          } else {
            let bit = s * d.bit_depth
            let byte = d.rows[at + bit / 8].to_int()
            (byte >> (8 - d.bit_depth - bit % 8)) & ((1 << d.bit_depth) - 1)
          }
          image[(y * d.width + x0 + i * dx) * n + c] = value
        }
      }
      at += row_bytes
    }
  }
  assert_eq(at, d.rows.length()) catch {
    _ => abort("rows of another length than the image's")
  }
  image
}

///|
/// The samples in pypng's shape: a byte each, two (big-endian) for 16 bits.
fn pypng_shape(d : Decoded, image : FixedArray[Int32]) -> Bytes {
  let out = Buffer()
  for v in image {
    if d.bit_depth == 16 {
      out.write_byte((v >> 8).to_byte())
    }
    out.write_byte(v.to_byte())
  }
  out.to_bytes()
}

///|
/// The data of the first chunk of type `name` in `png`.
fn chunk_data(png : Bytes, name : String) -> Bytes? {
  let mut at = 8
  while at + 8 <= png.length() {
    let length = (png[at].to_int() << 24) |
      (png[at + 1].to_int() << 16) |
      (png[at + 2].to_int() << 8) |
      png[at + 3].to_int()
    let mut found = true
    for i in 0..<4 {
      found = found && png[at + 4 + i] == name[i].to_byte()
    }
    if found {
      return Some(png[at + 8:at + 8 + length].to_owned())
    }
    at += 12 + length
  }
  None
}

///|
/// The image as typst's `decode_png` gives it, the shape of the `png`
/// crate's `EXPAND`: a palette applied (with tRNS as alpha), gray of fewer
/// than 8 bits scaled to 8, tRNS turned into an alpha channel, and 16-bit
/// samples little-endian when `swap16`, as typst gives them. The one place
/// the comparison converts.
fn expand(
  d : Decoded,
  trns : Bytes?,
  swap16~ : Bool = true,
) -> (@codecs.ColorType, Bytes) {
  let image = samples(d)
  let n = channels(d.color_type)
  let out = Buffer()
  let sample16 = (v : Int32) => {
    if swap16 {
      out.write_byte(v.to_byte())
      out.write_byte((v >> 8).to_byte())
    } else {
      out.write_byte((v >> 8).to_byte())
      out.write_byte(v.to_byte())
    }
  }
  let scale = (v : Int32) => {
    match d.bit_depth {
      1 => v * 255
      2 => v * 85
      4 => v * 17
      _ => v
    }
  }
  let pixels = d.width * d.height
  match d.color_type {
    IndexedColor => {
      let entries = d.palette.length() / 3
      for p in 0..<pixels {
        let index = image[p]
        for c in 0..<3 {
          out.write_byte(
            if index < entries {
              d.palette[index * 3 + c]
            } else {
              b'\x00'
            },
          )
        }
        if trns is Some(alpha) {
          out.write_byte(
            if index < alpha.length() {
              alpha[index]
            } else {
              b'\xff'
            },
          )
        }
      }
      (if trns is Some(_) { Rgba8 } else { Rgb8 }, out.to_bytes())
    }
    _ => {
      // tRNS for gray and truecolor: the one gray level or color, in 16-bit
      // fields, that is transparent.
      let key = match trns {
        Some(t) if n == 1 && t.length() >= 2 =>
          Some([(t[0].to_int() << 8) | t[1].to_int()])
        Some(t) if n == 3 && t.length() >= 6 =>
          Some([
            (t[0].to_int() << 8) | t[1].to_int(),
            (t[2].to_int() << 8) | t[3].to_int(),
            (t[4].to_int() << 8) | t[5].to_int(),
          ])
        _ => None
      }
      for p in 0..<pixels {
        let pixel = image[p * n:(p + 1) * n]
        for v in pixel {
          if d.bit_depth == 16 {
            sample16(v)
          } else {
            out.write_byte(scale(v).to_byte())
          }
        }
        if key is Some(key) {
          let mut transparent = true
          for c in 0..<n {
            transparent = transparent && pixel[c] == key[c]
          }
          if d.bit_depth == 16 {
            sample16(if transparent { 0 } else { 0xFFFF })
          } else {
            out.write_byte(if transparent { b'\x00' } else { b'\xff' })
          }
        }
      }
      let alpha = n == 2 || n == 4 || key is Some(_)
      let color : @codecs.ColorType = match (n, alpha, d.bit_depth == 16) {
        (1, false, false) => L8
        (1, false, true) => L16
        (1 | 2, true, false) => La8
        (1 | 2, true, true) => La16
        (3, false, false) => Rgb8
        (3, false, true) => Rgb16
        (_, _, false) => Rgba8
        _ => Rgba16
      }
      (color, out.to_bytes())
    }
  }
}

///|
/// The format of the image after `Header`, so that a decoder that reports
/// another under some split fails the checks.
fn describe_png(decoder : @png.Decoder, status : @codec_image.Status) -> String {
  if status is Header {
    let interlaced = if decoder.interlaced() { " interlaced" } else { "" }
    "\{@debug.to_string(decoder.color_type())} \{decoder.bit_depth()}\{interlaced}"
  } else {
    ""
  }
}

///|
fn png_stepper(
  until~ : @codec_image.Until = EndOfInput,
) -> @codec_harness.ImageDecoder[@png.Decoder] {
  @codec_harness.ImageDecoder::new(@png.Decoder(until~), describe=describe_png)
}

///|
/// What the decoder may hold for `d`: the zlib decoder and the palette, and
/// two rows of the image's width.
fn png_memory(d : Decoded) -> Int32 {
  let bits = channels(d.color_type) * d.bit_depth
  47_360 + 2 * (1 + packed_bytes(d.width, bits))
}

///|
test "PngSuite: the reference is pypng, and every image is there" {
  inspect(png_reference, content="pypng 0.20231004.0")
  let valid = png_vectors.filter(v => v.reference.has_prefix("ok "))
  let broken = png_vectors.filter(v => v.reference.has_prefix("error "))
  inspect(valid.length(), content="162")
  inspect(broken.length(), content="14")
  for v in broken {
    assert_true(broken_kinds.contains(v.name))
  }
}

///|
test "PngSuite: every valid image's samples are pypng's" {
  for v in png_vectors {
    guard v.reference.strip_prefix("ok ") is Some(expected) else { continue }
    let d = decode_png(v.input())
    let got = "\{d.width}x\{d.height} \{@codec_harness.sha256(pypng_shape(d, samples(d)))}"
    if got != expected.to_owned() {
      fail("\{v.name}: \{got}, pypng: \{expected}")
    }
  }
}

///|
test "PngSuite: every valid image under the harness's checks" {
  for i, v in png_vectors {
    guard v.reference.has_prefix("ok ") else { continue }
    let input = v.input()
    let d = decode_png(input)
    let memory_limit = Some(png_memory(d))
    let label = v.name
    let whole = @codec_harness.check_splits(
      () => png_stepper(),
      input,
      memory_limit~,
    ) catch {
      e => fail("\{label}: \{e}")
    }
    if whole.error is Some(_) || whole.output != d.rows {
      fail("\{label}: the harness's run gives other rows")
    }
    @codec_harness.check_truncation(
      () => png_stepper(),
      input,
      whole,
      max_prefixes=48,
    ) catch {
      e => fail("\{label}: \{e}")
    }
    @codec_harness.check_trailing(() => png_stepper(), input, whole, garbage=[
      b"x", b"\x89PNG",
    ]) catch {
      e => fail("\{label}: \{e}")
    }
    let next = png_vectors[(i + 1) % png_vectors.length()].input()
    @codec_harness.check_member(
      () => png_stepper(until=EndOfMember),
      input,
      next,
      whole,
    ) catch {
      e => fail("\{label} until=EndOfMember: \{e}")
    }
    @codec_harness.check_reset(() => png_stepper(), next, input) catch {
      e => fail("\{label}: \{e}")
    }
    let cut = input[:input.length() / 2]
    let _ = @codec_harness.check_error_splits(
      () => png_stepper(),
      cut,
      seed=i.reinterpret_as_uint(),
      memory_limit~,
    ) catch {
      e => fail("\{label} cut in half: \{e}")
    }
  }
}

///|
test "PngSuite: every broken image raises the kind its name says, under every split" {
  for i, v in png_vectors {
    guard v.reference.has_prefix("error ") else { continue }
    let run = @codec_harness.check_error_splits(
      () => png_stepper(),
      v.input(),
      seed=i.reinterpret_as_uint(),
      memory_limit=Some(47_360 + 2 * (1 + 256)),
    ) catch {
      e => fail("\{v.name}: \{e}")
    }
    let kind = run.error.map(k => @debug.to_string(k)).unwrap_or("none")
    if Some(kind) != broken_kinds.get(v.name) {
      fail("\{v.name}: \{kind}")
    }
  }
}

///|
test "PngSuite: corrupted images keep the contract" {
  let outcomes : Map[String, Int32] = Map([])
  for i, v in png_vectors {
    guard v.reference.has_prefix("ok ") && i % 8 == 0 else { continue }
    let found = @codec_harness.fuzz(
      () => png_stepper(),
      v.input(),
      seed=i.reinterpret_as_uint(),
      rounds=12,
      memory_limit=Some(47_360 + 2 * (1 + 768)),
    ) catch {
      e => fail("\{v.name}: \{e}")
    }
    for name, count in found {
      outcomes.set(name, outcomes.get_or_default(name, 0) + count)
    }
  }
  assert_true(outcomes.contains("Corrupt"))
  assert_true(outcomes.contains("ChecksumMismatch"))
}

///|
test "PngSuite: typst's decode_png agrees, after EXPAND" {
  for v in png_vectors {
    let input = v.input()
    let theirs = Some(@codecs.decode_png(input)) catch { _ => None }
    guard v.reference.has_prefix("ok ") else {
      if theirs is Some(_) {
        fail("\{v.name}: typst decodes a broken image")
      }
      continue
    }
    guard theirs is Some((info, pixels)) else {
      fail("\{v.name}: typst refuses it")
    }
    let d = decode_png(input)
    let (color, ours) = expand(d, chunk_data(input, "tRNS"))
    if info.width != d.width.reinterpret_as_uint() ||
      info.height != d.height.reinterpret_as_uint() ||
      info.color != color ||
      pixels != ours {
      fail(
        "\{v.name}: typst gives \{@debug.to_string(info.color)}, ours \{@debug.to_string(color)}, \{pixels.length()} and \{ours.length()} bytes",
      )
    }
  }
}

///|
test "PngSuite: without swapping 16-bit samples, no 16-bit image agrees with typst" {
  // The negative control of the comparison above: it would pass for the
  // wrong byte order only if the conversion were not where the bytes are
  // compared.
  let mut sixteen = 0
  for v in png_vectors {
    guard v.reference.has_prefix("ok ") else { continue }
    let input = v.input()
    let d = decode_png(input)
    guard d.bit_depth == 16 else { continue }
    let (_, pixels) = @codecs.decode_png(input)
    let (_, swapped) = expand(d, chunk_data(input, "tRNS"))
    let (_, unswapped) = expand(d, chunk_data(input, "tRNS"), swap16=false)
    // An image whose every sample has two equal bytes (8-bit levels times
    // 257) reads the same either way, and tells nothing.
    if swapped == unswapped {
      continue
    }
    if pixels == unswapped {
      fail("\{v.name}: agrees in big-endian order")
    }
    sixteen += 1
  }
  inspect(sixteen, content="27")
}
