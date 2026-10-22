// gaato/png over PngSuite (png_vectors_test.mbt): every image against
// pypng's samples and fixed-length chunks, its text chunks against Python's
// zlib, against typst's decode_png, and under the harness's checks through
// the image adapter, with the text and profile chunks reported.

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
  /// What the decoder read of the fixed-length chunks pypng also reads, as
  /// the reference writes it.
  fields : Array[String]
  /// The blocks of the text and profile chunks, each with its type.
  blocks : Array[(String, Bytes)]
  /// The rows and the blocks, in the order the decoder wrote them.
  output : Bytes
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
/// The chunk types the tests report.
let reported : Array[String] = ["tEXt", "zTXt", "iTXt", "iCCP"]

///|
/// Decodes `input` whole with a fresh decoder that reports the text and
/// profile chunks.
fn decode_png(input : Bytes) -> Decoded raise {
  let decoder = @png.Decoder(report=reported)
  let blocks = []
  let output = Buffer()
  let rows = Buffer()
  let mut out = FixedArray::make(0, b'\x00')
  let mut rest = input[:]
  for ;; {
    if out.length() < decoder.room_needed() {
      out = FixedArray::make(decoder.room_needed() * 8, b'\x00')
    }
    let status = decoder.step(rest, out.mut_view(), end=true)
    rest = rest[decoder.last_consumed():]
    output.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
    match status {
      Rows => rows.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
      Metadata =>
        blocks.push(
          (
            decoder.metadata_type(),
            Bytes::from_array(out[:decoder.last_produced()]),
          ),
        )
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
    fields: fields_of(decoder),
    blocks,
    output: output.to_bytes(),
  }
}

///|
fn joined(values : Array[Int32]) -> String {
  values.map(v => v.to_string()).join(",")
}

///|
/// The fixed-length chunks as the reference writes what pypng reads of
/// them: gAMA, tRNS (for indexed-color, the alpha of every palette entry),
/// bKGD, pHYs, sBIT.
fn fields_of(decoder : @png.Decoder) -> Array[String] {
  let out = []
  if decoder.gamma() is Some(gamma) {
    out.push("gAMA \{gamma}")
  }
  match decoder.transparency() {
    Some(Gray(v)) => out.push("tRNS \{v}")
    Some(Rgb(r, g, b)) => out.push("tRNS \{joined([r, g, b])}")
    Some(Alpha(alpha)) => {
      let entries = decoder.palette().length() / 3
      let all = Array::makei(entries, i => {
        if i < alpha.length() {
          alpha[i].to_int()
        } else {
          255
        }
      })
      out.push("alpha \{joined(all)}")
    }
    None => ()
  }
  match decoder.background() {
    Some(Gray(v)) | Some(Index(v)) => out.push("bKGD \{v}")
    Some(Rgb(r, g, b)) => out.push("bKGD \{joined([r, g, b])}")
    None => ()
  }
  if decoder.physical_size() is Some(size) {
    let metre = if size.per_meter { 1 } else { 0 }
    out.push("pHYs \{size.x},\{size.y},\{metre}")
  }
  let sbit = decoder.significant_bits()
  if sbit.length() > 0 {
    out.push("sBIT \{joined(sbit.to_owned().map(b => b.to_int()))}")
  }
  out
}

///|
/// `text <count> <digest>` of `blocks`, as the reference writes it: the
/// first 16 hex digits of the SHA-256 of each block's type, length and
/// bytes, one after another.
fn text_digest(blocks : Array[(String, Bytes)]) -> String {
  let all = Buffer()
  for block in blocks {
    let (kind, bytes) = block
    for c in kind {
      all.write_byte(c.to_int().to_byte())
    }
    let n = bytes.length()
    for shift in [24, 16, 8, 0] {
      all.write_byte((n >> shift).to_byte())
    }
    all.write_bytes(bytes)
  }
  let digest = @codec_harness.sha256(all.to_bytes())
  "text \{blocks.length()} \{digest.view(end_offset=16)}"
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
/// The image as typst's `decode_png` gives it: gaato/png's one-shot
/// `decode`, each row through its converter's `expanded` (the png crate's
/// EXPAND, which typst ports), and 16-bit samples swapped to little-endian
/// when `swap16`, as typst gives them. The swap is the one conversion the
/// comparison makes itself.
fn expand(
  input : Bytes,
  swap16~ : Bool = true,
) -> (@codecs.ColorType, Bytes) raise {
  let image = @png.decode(input)
  let converter = image.converter
  let channels = converter.expanded_channels()
  let depth = converter.expanded_depth()
  let per_row = image.width * channels * depth / 8
  let out = FixedArray::make(per_row * image.height, b'\x00')
  for y in 0..<image.height {
    converter.expanded(
      image.row(y),
      image.width,
      out.mut_view(start=y * per_row, end=(y + 1) * per_row),
    )
  }
  if swap16 && depth == 16 {
    for i = 0; i + 1 < out.length(); i = i + 2 {
      let high = out[i]
      out[i] = out[i + 1]
      out[i + 1] = high
    }
  }
  let color : @codecs.ColorType = match (channels, depth) {
    (1, 8) => L8
    (1, _) => L16
    (2, 8) => La8
    (2, _) => La16
    (3, 8) => Rgb8
    (3, _) => Rgb16
    (_, 8) => Rgba8
    _ => Rgba16
  }
  (color, Bytes::from_array(out[:]))
}

///|
/// The format of the image after `Header`, so that a decoder that reports
/// another under some split fails the checks.
fn describe_png(decoder : @png.Decoder, status : @codec_image.Status) -> String {
  match status {
    Header => {
      let interlaced = if decoder.interlaced() { " interlaced" } else { "" }
      "\{@debug.to_string(decoder.color_type())} \{decoder.bit_depth()}\{interlaced}"
    }
    Metadata => decoder.metadata_type()
    _ => ""
  }
}

///|
fn png_stepper(
  until~ : @codec_image.Until = EndOfInput,
) -> @codec_harness.ImageDecoder[@png.Decoder] {
  @codec_harness.ImageDecoder::new(
    @png.Decoder(report=reported, until~),
    describe=describe_png,
  )
}

///|
/// What the decoder may hold for `d`: the two zlib decoders and the
/// palette, two rows of the image's width, and the buffer of its largest
/// block, which grows by doubling from 256 bytes, or is the chunk's length.
fn png_memory(d : Decoded, input : Bytes) -> Int32 {
  let bits = channels(d.color_type) * d.bit_depth
  let block = d.blocks.fold(init=0, (most, b) => most.max(b.1.length()))
  47_360 +
  46_592 +
  2 * (1 + packed_bytes(d.width, bits)) +
  (2 * block).max(256).max(input.length())
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
test "PngSuite: every valid image's samples, fixed-length chunks and text are what the reference says" {
  for v in png_vectors {
    guard v.reference.strip_prefix("ok ") is Some(expected) else { continue }
    let d = decode_png(v.input())
    let got = [
      "\{d.width}x\{d.height} \{@codec_harness.sha256(pypng_shape(d, samples(d)))}",
      ..d.fields,
      text_digest(d.blocks),
    ].join("; ")
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
    let memory_limit = Some(png_memory(d, input))
    let label = v.name
    let whole = @codec_harness.check_splits(
      () => png_stepper(),
      input,
      memory_limit~,
    ) catch {
      e => fail("\{label}: \{e}")
    }
    if whole.error is Some(_) || whole.output != d.output {
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
      memory_limit=Some(47_360 + 46_592 + 2 * (1 + 256) + 256),
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
      memory_limit=Some(47_360 + 46_592 + 2 * (1 + 768) + (1 << 20)),
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
    let (color, ours) = expand(input)
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
    let (_, swapped) = expand(input)
    let (_, unswapped) = expand(input, swap16=false)
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
