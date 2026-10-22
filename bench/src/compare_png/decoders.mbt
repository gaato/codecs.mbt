///|
/// An image as straight (not premultiplied) RGBA, 16 bits a sample,
/// big-endian, row after row: the shape every decoder's output is brought
/// to, so that they can be compared byte for byte. Samples of fewer bits are
/// widened by repeating their bits (an 8-bit `v` is `v * 257`), which is
/// exact and is what each decoder does when it widens.
pub(all) struct Rgba16 {
  width : Int32
  height : Int32
  pixels : Bytes
}

///|
/// Whether two images have the same size and pixels.
pub fn Rgba16::same(self : Rgba16, other : Rgba16) -> Bool {
  self.width == other.width &&
  self.height == other.height &&
  self.pixels == other.pixels
}

///|
/// A decoder refused the file, with its message.
pub(all) suberror Refused {
  Refused(String)
}

///|
/// The decoders compared, by the name the runners take.
pub let decoders : Array[String] = [
  "gaato", "gaato-stream", "typst", "gmlewis", "mizchi",
]

///|
/// Decodes `input` with the decoder named `name`, one of `decoders`.
pub fn decode_with(name : String, input : Bytes) -> Rgba16 raise Refused {
  match name {
    "gaato" => gaato(input)
    "gaato-stream" => gaato_stream(input)
    "typst" => typst(input)
    "gmlewis" => gmlewis(input)
    "mizchi" => mizchi(input)
    _ => abort("no decoder \{name}")
  }
}

///|
fn put16(out : FixedArray[Byte], at : Int32, v : Int32) -> Unit {
  out[at] = (v >> 8).to_byte()
  out[at + 1] = v.to_byte()
}

///|
/// The sample at `s` of a row of `depth`-bit samples, widened to 16 bits.
fn sample16(row : ArrayView[Byte], s : Int32, depth : Int32) -> Int32 {
  match depth {
    16 => (row[2 * s].to_int() << 8) | row[2 * s + 1].to_int()
    8 => row[s].to_int() * 257
    _ => {
      let bit = s * depth
      let v = (row[bit / 8].to_int() >> (8 - depth - bit % 8)) &
        ((1 << depth) - 1)
      v * (65535 / ((1 << depth) - 1))
    }
  }
}

///|
/// The raw sample at `s`, not widened.
fn sample(row : ArrayView[Byte], s : Int32, depth : Int32) -> Int32 {
  match depth {
    16 => (row[2 * s].to_int() << 8) | row[2 * s + 1].to_int()
    8 => row[s].to_int()
    _ => {
      let bit = s * depth
      (row[bit / 8].to_int() >> (8 - depth - bit % 8)) & ((1 << depth) - 1)
    }
  }
}

///|
/// The image gaato/png reads, brought to `Rgba16` here rather than by its
/// own `Converter`: the samples of `decode`'s deinterlaced rows (which the
/// conformance suite checks against pypng's on all of PngSuite), with the
/// palette and tRNS that its streaming decoder reads applied as the
/// specification says: an index past the palette is opaque black, a pixel
/// whose samples equal tRNS's is transparent. `max_output` is `decode`'s.
pub fn gaato(input : Bytes, max_output? : Int32) -> Rgba16 raise Refused {
  let image = @png.decode(input, max_output?) catch {
    e => raise Refused(@debug.to_string(e))
  }
  let (palette, transparency) = chunks_of(input)
  let w = image.width
  let depth = image.bit_depth
  let out = FixedArray::make(w * image.height * 8, b'\x00')
  for y in 0..<image.height {
    let row = image.row(y)
    for x in 0..<w {
      let at = (y * w + x) * 8
      let (r, g, b, a) = match image.color_type {
        Grayscale => {
          let v = sample16(row, x, depth)
          let a = match transparency {
            Some(Gray(t)) if sample(row, x, depth) == t => 0
            _ => 65535
          }
          (v, v, v, a)
        }
        GrayscaleAlpha =>
          (
            sample16(row, 2 * x, depth),
            sample16(row, 2 * x, depth),
            sample16(row, 2 * x, depth),
            sample16(row, 2 * x + 1, depth),
          )
        Truecolor => {
          let a = match transparency {
            Some(Rgb(tr, tg, tb)) if sample(row, 3 * x, depth) == tr &&
              sample(row, 3 * x + 1, depth) == tg &&
              sample(row, 3 * x + 2, depth) == tb => 0
            _ => 65535
          }
          (
            sample16(row, 3 * x, depth),
            sample16(row, 3 * x + 1, depth),
            sample16(row, 3 * x + 2, depth),
            a,
          )
        }
        TruecolorAlpha =>
          (
            sample16(row, 4 * x, depth),
            sample16(row, 4 * x + 1, depth),
            sample16(row, 4 * x + 2, depth),
            sample16(row, 4 * x + 3, depth),
          )
        IndexedColor => {
          let i = sample(row, x, depth)
          if 3 * i + 2 < palette.length() {
            let a = match transparency {
              Some(Alpha(alpha)) if i < alpha.length() =>
                alpha[i].to_int() * 257
              _ => 65535
            }
            (
              palette[3 * i].to_int() * 257,
              palette[3 * i + 1].to_int() * 257,
              palette[3 * i + 2].to_int() * 257,
              a,
            )
          } else {
            (0, 0, 0, 65535)
          }
        }
      }
      put16(out, at, r)
      put16(out, at + 2, g)
      put16(out, at + 4, b)
      put16(out, at + 6, a)
    }
  }
  { width: w, height: image.height, pixels: Bytes::from_array(out[:]), }
}

///|
/// gaato/png's streaming decoder, with its default limits, over `input`
/// given whole, into a 64 KiB slice: the rows are not kept, so the image is
/// not compared (`gaato` is), only whether the decoder takes the file.
pub fn gaato_stream(input : Bytes) -> Rgba16 raise Refused {
  let decoder = @png.Decoder()
  let mut out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  for ;; {
    if out.length() < decoder.room_needed() {
      out = FixedArray::make(decoder.room_needed(), b'\x00')
    }
    let status = decoder.step_into(rest, out, end=true) catch {
      e => raise Refused(@debug.to_string(e))
    }
    rest = rest[decoder.last_consumed():]
    if status is Done {
      return { width: decoder.width(), height: decoder.height(), pixels: b"", }
    }
  }
}

///|
/// The palette and tRNS that gaato/png's streaming decoder reads in `input`.
fn chunks_of(input : Bytes) -> (Bytes, @png.Transparency?) raise Refused {
  let decoder = @png.Decoder(animation=false)
  let mut out = FixedArray::make(0, b'\x00')
  let mut rest = input[:]
  for ;; {
    if out.length() < decoder.room_needed() {
      out = FixedArray::make(decoder.room_needed(), b'\x00')
    }
    let status = decoder.step_into(rest, out, end=true) catch {
      e => raise Refused(@debug.to_string(e))
    }
    rest = rest[decoder.last_consumed():]
    if status is Done {
      let transparency = match decoder.transparency() {
        // The view lives in the decoder: copy it out.
        Some(Alpha(alpha)) =>
          Some(@png.Transparency::Alpha(alpha.to_owned()[:]))
        other => other
      }
      return (Bytes::from_array(decoder.palette()), transparency)
    }
  }
}

///|
/// typst's `decode_png`, a port of the png crate with its EXPAND
/// transformation: gray, gray and alpha, RGB or RGBA at 8 or 16 bits, the
/// 16-bit samples little-endian.
pub fn typst(input : Bytes) -> Rgba16 raise Refused {
  let (info, pixels) = @codecs.decode_png(input) catch {
    @codecs.ImageError(message) => raise Refused(message)
  }
  let w = info.width.reinterpret_as_int()
  let h = info.height.reinterpret_as_int()
  let (channels, wide) = match info.color {
    L8 => (1, false)
    La8 => (2, false)
    Rgb8 => (3, false)
    Rgba8 => (4, false)
    L16 => (1, true)
    La16 => (2, true)
    Rgb16 => (3, true)
    Rgba16 => (4, true)
  }
  let n = w * h
  let size = if wide { 2 } else { 1 }
  guard pixels.length() == n * channels * size else {
    raise Refused("typst: \{pixels.length()} bytes for \{w}x\{h}")
  }
  let out = FixedArray::make(n * 8, b'\x00')
  fn get(i : Int32) -> Int32 {
    if wide {
      pixels[2 * i].to_int() | (pixels[2 * i + 1].to_int() << 8)
    } else {
      pixels[i].to_int() * 257
    }
  }

  for p in 0..<n {
    let s = p * channels
    let (r, g, b, a) = match channels {
      1 => (get(s), get(s), get(s), 65535)
      2 => (get(s), get(s), get(s), get(s + 1))
      3 => (get(s), get(s + 1), get(s + 2), 65535)
      _ => (get(s), get(s + 1), get(s + 2), get(s + 3))
    }
    put16(out, p * 8, r)
    put16(out, p * 8 + 2, g)
    put16(out, p * 8 + 4, b)
    put16(out, p * 8 + 6, a)
  }
  { width: w, height: h, pixels: Bytes::from_array(out[:]), }
}

///|
/// gmlewis/image's `png.decode`, a port of Go's image/png, which gives an
/// image of Go's color models; each pixel is read through `at` in its own
/// model (`raw`), so that no premultiplied value is taken for a straight one.
pub fn gmlewis(input : Bytes) -> Rgba16 raise Refused {
  let reader : &@io.Reader = @io.Buffer::from_bytes(input)
  let (image, error) = @gpng.decode(reader)
  if error is Some(e) {
    raise Refused(e.to_string())
  }
  let bounds = image.bounds()
  let w = bounds.max.x - bounds.min.x
  let h = bounds.max.y - bounds.min.y
  let out = FixedArray::make(w * h * 8, b'\x00')
  for y in 0..<h {
    for x in 0..<w {
      let c = image.at(bounds.min.x + x, bounds.min.y + y)
      let (r, g, b, a) = c.raw()
      let (r, g, b, a) = match c.model() {
        "Gray" => (r * 257, r * 257, r * 257, 65535U)
        "Gray16" => (r, r, r, 65535U)
        // Premultiplied; PNG's truecolor images without alpha come as these,
        // always opaque.
        "RGBA" | "NRGBA" => (r * 257, g * 257, b * 257, a * 257)
        "RGBA64" | "NRGBA64" => (r, g, b, a)
        model => raise Refused("gmlewis: color model \{model}")
      }
      if c.model() is ("RGBA" | "RGBA64") && a != 65535 {
        raise Refused("gmlewis: premultiplied pixel with alpha \{a}")
      }
      let at = (y * w + x) * 8
      put16(out, at, r.reinterpret_as_int())
      put16(out, at + 2, g.reinterpret_as_int())
      put16(out, at + 4, b.reinterpret_as_int())
      put16(out, at + 6, a.reinterpret_as_int())
    }
  }
  { width: w, height: h, pixels: Bytes::from_array(out[:]), }
}

///|
/// mizchi/image's `decode_png`, which gives RGBA, 8 bits a sample.
pub fn mizchi(input : Bytes) -> Rgba16 raise Refused {
  let image = @mimage.decode_png(input) catch {
    e => raise Refused(e.to_string())
  }
  let n = image.width * image.height
  guard image.data.length() == n * 4 else {
    raise Refused("mizchi: \{image.data.length()} bytes for \{n} pixels")
  }
  let out = FixedArray::make(n * 8, b'\x00')
  for i in 0..<(n * 4) {
    put16(out, 2 * i, image.data[i].to_int() * 257)
  }
  {
    width: image.width,
    height: image.height,
    pixels: Bytes::from_array(out[:]),
  }
}

///|
/// Decodes `input` with the package named `name` (`typst`, `gmlewis` or
/// `mizchi`) through its own call, its output as it gives it: the image's
/// width, height and bytes of pixels. What the benchmarks time and the
/// memory runs measure, without the conversion to `Rgba16`.
pub fn decode_native(
  name : String,
  input : Bytes,
) -> (Int32, Int32, Int32) raise Refused {
  match name {
    "typst" => {
      let (info, pixels) = @codecs.decode_png(input) catch {
        @codecs.ImageError(message) => raise Refused(message)
      }
      (
        info.width.reinterpret_as_int(),
        info.height.reinterpret_as_int(),
        pixels.length(),
      )
    }
    "gmlewis" => {
      let reader : &@io.Reader = @io.Buffer::from_bytes(input)
      let (image, error) = @gpng.decode(reader)
      if error is Some(e) {
        raise Refused(e.to_string())
      }
      let bounds = image.bounds()
      (
        bounds.max.x - bounds.min.x,
        bounds.max.y - bounds.min.y,
        image.raw_data().length(),
      )
    }
    "mizchi" => {
      let image = @mimage.decode_png(input) catch {
        e => raise Refused(e.to_string())
      }
      (image.width, image.height, image.data.length())
    }
    _ => abort("no decoder \{name}")
  }
}
