// Converting rows from PNG's own layout, the one the decoder writes, to
// RGBA and to the shape of the png crate's EXPAND. The arithmetic of a
// sample is `@convert`'s; here are the rows, the palette's table, and tRNS.

///|
/// Converts rows of one image (or frame: its rows have the image's layout)
/// to other layouts. Made from what the image says: its color type, bit
/// depth, palette and tRNS (`Decoder::converter`, or
/// `Converter::Converter`).
pub struct Converter {
  priv color_type : Int32
  priv bit_depth : Int32
  // RGBA for each of the 256 indices: the palette's entries with tRNS's
  // alpha, and opaque black for the indices past them.
  priv table : FixedArray[Byte]
  // tRNS for grayscale and truecolor: the level or color that is
  // transparent.
  priv key : FixedArray[Int32]
  priv keyed : Bool
  // Whether tRNS gave the palette's alpha.
  priv alpha : Bool
}

///|
/// A converter for rows of `color_type` and `bit_depth`. `palette` is
/// PLTE's red, green and blue bytes (for indexed-color); `transparency` is
/// tRNS, as `Decoder::transparency` gives it. An index past the palette
/// converts to opaque black (13.1); every other value converts as it is.
pub fn Converter::Converter(
  color_type : ColorType,
  bit_depth : Int32,
  palette? : ArrayView[Byte],
  transparency? : Transparency,
) -> Converter {
  let table = FixedArray::make(256 * 4, b'\x00')
  for i in 0..<256 {
    table[i * 4 + 3] = b'\xff'
  }
  if palette is Some(palette) {
    for i in 0..<(palette.length() / 3).min(256) {
      for c in 0..<3 {
        table[i * 4 + c] = palette[i * 3 + c]
      }
    }
  }
  let key = FixedArray::make(3, 0)
  let mut keyed = false
  match transparency {
    Some(Alpha(alpha)) =>
      for i in 0..<alpha.length().min(256) {
        table[i * 4 + 3] = alpha[i]
      }
    Some(Gray(v)) => {
      key[0] = v
      keyed = true
    }
    Some(Rgb(r, g, b)) => {
      key[0] = r
      key[1] = g
      key[2] = b
      keyed = true
    }
    None => ()
  }
  let color_type = match color_type {
    Grayscale => 0
    Truecolor => 2
    IndexedColor => 3
    GrayscaleAlpha => 4
    TruecolorAlpha => 6
  }
  let alpha = transparency is Some(Alpha(_))
  { color_type, bit_depth, table, key, keyed, alpha, }
}

///|
/// A converter for the decoder's image: its color type, bit depth, palette
/// and tRNS. Valid from `Frame` until `reset`.
pub fn Decoder::converter(self : Decoder) -> Converter {
  Converter::Converter(
    self.color_type(),
    self.bit_depth,
    palette=self.palette(),
    transparency?=self.transparency(),
  )
}

///|
/// Sample `i` of `row`, of `bit_depth` bits.
fn sample(row : ArrayView[Byte], i : Int32, bit_depth : Int32) -> Int32 {
  match bit_depth {
    16 => (row[2 * i].to_int() << 8) | row[2 * i + 1].to_int()
    8 => row[i].to_int()
    _ => {
      let per_byte = 8 / bit_depth
      @convert.packed_sample(
        row[i / per_byte].to_int(),
        i % per_byte,
        bit_depth,
      )
    }
  }
}

///|
/// The channels a pixel of the converter's color type has in the row.
fn Converter::channels(self : Converter) -> Int32 {
  @rules.channels(self.color_type)
}

///|
/// Whether pixel `p` of `row` is the color tRNS makes transparent.
fn Converter::transparent(
  self : Converter,
  row : ArrayView[Byte],
  p : Int32,
) -> Bool {
  guard self.keyed else { return false }
  let n = self.channels()
  for c in 0..<n {
    if sample(row, p * n + c, self.bit_depth) != self.key[c] {
      return false
    }
  }
  true
}

///|
/// Writes the first `pixels` pixels of `row` into `into` as 8-bit RGBA, four
/// bytes a pixel: the palette applied, gray repeated in red, green and blue,
/// samples of fewer than 8 bits widened by repeating their bits, 16-bit ones
/// rounded to 8, and alpha from the image's alpha channel, from tRNS, or
/// 255. `into` holds at least `4 × pixels` bytes.
pub fn Converter::rgba8(
  self : Converter,
  row : ArrayView[Byte],
  pixels : Int32,
  into : MutArrayView[Byte],
) -> Unit {
  let d = self.bit_depth
  let n = self.channels()
  let to8 = (v : Int32) => {
    if d == 16 {
      @convert.narrow(v)
    } else {
      @convert.widen(v, d)
    }
  }
  for p in 0..<pixels {
    let o = 4 * p
    if self.color_type == 3 {
      let index = sample(row, p, d)
      for c in 0..<4 {
        into[o + c] = self.table[index * 4 + c]
      }
      continue
    }
    let first = to8(sample(row, p * n, d))
    let gray = (self.color_type & 2) == 0
    into[o] = first.to_byte()
    into[o + 1] = (if gray { first } else { to8(sample(row, p * n + 1, d)) }).to_byte()
    into[o + 2] = (if gray { first } else { to8(sample(row, p * n + 2, d)) }).to_byte()
    into[o + 3] = if (self.color_type & 4) != 0 {
      to8(sample(row, p * n + n - 1, d)).to_byte()
    } else if self.transparent(row, p) {
      b'\x00'
    } else {
      b'\xff'
    }
  }
}

///|
/// Writes the first `pixels` pixels of `row` into `into` as 16-bit RGBA,
/// eight bytes a pixel, each sample big-endian: as `rgba8`, but samples of
/// fewer than 16 bits widened to 16 by repeating their bits, and 16-bit ones
/// as they are. `into` holds at least `8 × pixels` bytes.
pub fn Converter::rgba16(
  self : Converter,
  row : ArrayView[Byte],
  pixels : Int32,
  into : MutArrayView[Byte],
) -> Unit {
  let d = self.bit_depth
  let n = self.channels()
  let to16 = (v : Int32) => if d == 16 { v } else { @convert.widen(v, d) * 257 }
  let put = (at : Int32, v : Int32) => {
    into[at] = (v >> 8).to_byte()
    into[at + 1] = v.to_byte()
  }
  for p in 0..<pixels {
    let o = 8 * p
    if self.color_type == 3 {
      let index = sample(row, p, d)
      for c in 0..<4 {
        put(o + 2 * c, self.table[index * 4 + c].to_int() * 257)
      }
      continue
    }
    let first = to16(sample(row, p * n, d))
    let gray = (self.color_type & 2) == 0
    put(o, first)
    put(o + 2, if gray { first } else { to16(sample(row, p * n + 1, d)) })
    put(o + 4, if gray { first } else { to16(sample(row, p * n + 2, d)) })
    put(
      o + 6,
      if (self.color_type & 4) != 0 {
        to16(sample(row, p * n + n - 1, d))
      } else if self.transparent(row, p) {
        0
      } else {
        0xFFFF
      },
    )
  }
}

///|
/// The channels of a pixel `expanded` writes: 1 (gray), 2 (gray and alpha),
/// 3 (RGB) or 4 (RGBA).
pub fn Converter::expanded_channels(self : Converter) -> Int32 {
  match self.color_type {
    3 => if self.alpha { 4 } else { 3 }
    0 | 2 => self.channels() + (if self.keyed { 1 } else { 0 })
    _ => self.channels()
  }
}

///|
/// The bits of a sample `expanded` writes: 16 for a 16-bit image, else 8.
pub fn Converter::expanded_depth(self : Converter) -> Int32 {
  if self.bit_depth == 16 {
    16
  } else {
    8
  }
}

///|
/// Writes the first `pixels` pixels of `row` into `into` as the png crate's
/// EXPAND does, which libpng's `png_set_expand` matches: the palette applied,
/// to RGB, or RGBA with tRNS; gray of fewer than 8 bits widened to 8; tRNS
/// of grayscale and truecolor images turned into an alpha channel; 16-bit
/// samples kept, big-endian. `expanded_channels` and `expanded_depth` say
/// the layout; `into` holds at least their product, in bytes, times
/// `pixels`.
pub fn Converter::expanded(
  self : Converter,
  row : ArrayView[Byte],
  pixels : Int32,
  into : MutArrayView[Byte],
) -> Unit {
  let d = self.bit_depth
  let n = self.channels()
  let out_channels = self.expanded_channels()
  let mut at = 0
  for p in 0..<pixels {
    if self.color_type == 3 {
      let index = sample(row, p, d)
      for c in 0..<out_channels {
        into[at + c] = self.table[index * 4 + c]
      }
      at += out_channels
      continue
    }
    for c in 0..<n {
      let v = sample(row, p * n + c, d)
      if d == 16 {
        into[at] = (v >> 8).to_byte()
        into[at + 1] = v.to_byte()
        at += 2
      } else {
        into[at] = @convert.widen(v, d).to_byte()
        at += 1
      }
    }
    if out_channels > n {
      let alpha = if self.transparent(row, p) { 0 } else { 0xFFFF }
      if d == 16 {
        into[at] = (alpha >> 8).to_byte()
        into[at + 1] = alpha.to_byte()
        at += 2
      } else {
        into[at] = alpha.to_byte()
        at += 1
      }
    }
  }
}
