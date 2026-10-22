///|
/// Whether `data` begins with PNG's 8-byte signature (5.2): whether it is a
/// PNG image (or APNG), from its first bytes. Fewer than 8 bytes are not.
pub fn is_signature(data : BytesView) -> Bool {
  data.length() >= 8 &&
  data[0] == b'\x89' &&
  data[1] == b'P' &&
  data[2] == b'N' &&
  data[3] == b'G' &&
  data[4] == b'\r' &&
  data[5] == b'\n' &&
  data[6] == b'\x1a' &&
  data[7] == b'\n'
}

///|
/// A whole image, as `decode` gives it: its rows one after another, in
/// PNG's own layout (see `Converter` for others), deinterlaced, with what
/// the image says about them.
pub struct Image {
  width : Int32
  height : Int32
  color_type : ColorType
  bit_depth : Int32
  /// The bytes of a row: ceil(width × bits a pixel / 8).
  row_bytes : Int32
  /// The rows, `row_bytes` each, from the top.
  pixels : FixedArray[Byte]
  /// A converter for the rows, with the image's palette and tRNS.
  converter : Converter
}

///|
/// Row `y` of the image, from 0 at the top.
pub fn Image::row(self : Image, y : Int32) -> ArrayView[Byte] {
  self.pixels[y * self.row_bytes:(y + 1) * self.row_bytes]
}

///|
/// Decodes a whole PNG image held in `input`, an APNG's default image
/// alone, and returns it once every CRC and the Adler-32 have passed.
///
/// `max_output` bounds the bytes of the rows, from what IHDR says, before
/// anything is allocated for them: an image of more raises
/// `LimitExceeded(Output)` with their size. Unbounded by default; the
/// decoder's own limits (`max_row_bytes`) apply either way. Ancillary chunks
/// are read as the streaming decoder reads them, and none is reported.
pub fn decode(
  input : BytesView,
  max_output? : Int32,
) -> Image raise @codec.CodecError {
  let decoder = Decoder(animation=false)
  let mut out = FixedArray::make(0, b'\x00')
  let mut image = FixedArray::make(0, b'\x00')
  let mut row_bytes = 0
  let mut bits = 0
  let mut rest = input
  for ;; {
    if out.length() < decoder.room_needed() {
      out = FixedArray::make(decoder.room_needed().max(1 << 16), b'\x00')
    }
    let status = decoder.step_into(rest, out, end=true)
    rest = rest[decoder.last_consumed():]
    match status {
      Header => {
        bits = @rules.channels(decoder.color_type) * decoder.bit_depth
        let wide = (decoder.width.to_int64() * bits.to_int64() + 7L) / 8L
        let needed = wide * decoder.height.to_int64()
        if max_output is Some(limit) && needed > limit.to_int64() {
          raise @codec.CodecError(
            LimitExceeded({
              resource: Output,
              needed: Some(needed.reinterpret_as_uint64()),
              limit: limit.max(0).to_uint64(),
            }),
            "an image of \{needed} bytes, over max_output",
          )
        }
        // Row sizes beyond the decoder's limit raise at the next step,
        // before this is allocated.
        if wide <= decoder.max_row_bytes.to_int64() && needed <= 0x7FFFFFFFL {
          row_bytes = wide.to_int()
          image = FixedArray::make(needed.to_int(), b'\x00')
        } else if wide <= decoder.max_row_bytes.to_int64() {
          raise @codec.CodecError(
            LimitExceeded({
              resource: Output,
              needed: Some(needed.reinterpret_as_uint64()),
              limit: 0x7FFFFFFFUL,
            }),
            "an image of \{needed} bytes, more than an array holds",
          )
        }
      }
      Rows => {
        let n = decoder.row_bytes()
        for r in 0..<decoder.rows_count() {
          let y = decoder.pass_y() +
            (decoder.rows_first() + r) * decoder.pass_dy()
          scatter(
            out[r * n:(r + 1) * n],
            @rules.pass_columns(
              decoder.interlaced,
              decoder.pass(),
              decoder.width,
            ),
            bits,
            decoder.pass_x(),
            decoder.pass_dx(),
            image.mut_view(start=y * row_bytes, end=(y + 1) * row_bytes),
          )
        }
      }
      Done =>
        return {
          width: decoder.width,
          height: decoder.height,
          color_type: decoder.color_type(),
          bit_depth: decoder.bit_depth,
          row_bytes,
          pixels: image,
          converter: decoder.converter(),
        }
      _ => ()
    }
  }
}
