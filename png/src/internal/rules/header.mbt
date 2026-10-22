///|
/// The channels of a pixel of each color type, 0 for the types table 11
/// does not define.
let channels_of : FixedArray[Int32] = [1, 0, 3, 1, 2, 0, 4]

///|
/// The bit depths table 12 allows for each color type, bit `k` for depth
/// `2^k`: grayscale 1 to 16, truecolor 8 and 16, indexed-color 1 to 8,
/// grayscale with alpha and truecolor with alpha 8 and 16.
let depths_of : FixedArray[Int32] = [0x1F, 0, 0x18, 0x0F, 0x18, 0, 0x18]

///|
/// Whether table 12 allows `bit_depth` with `color_type`.
pub fn is_allowed(color_type : Int32, bit_depth : Int32) -> Bool {
  guard color_type >= 0 && color_type < channels_of.length() else {
    return false
  }
  let k = match bit_depth {
    1 => 0
    2 => 1
    4 => 2
    8 => 3
    16 => 4
    _ => return false
  }
  ((depths_of[color_type] >> k) & 1) == 1
}

///|
/// The channels of a pixel of `color_type`, which `is_allowed` accepts.
pub fn channels(color_type : Int32) -> Int32 {
  channels_of[color_type]
}

///|
/// Why the fields of an IHDR chunk do not describe an image (11.2.1), or
/// `None` when they do: width and height from 1 to 2^31 − 1, a color type
/// and bit depth of table 12, compression and filter method 0, and
/// interlace method 0 or 1.
pub fn check_header(
  width : UInt32,
  height : UInt32,
  bit_depth : Int32,
  color_type : Int32,
  compression : Int32,
  filter : Int32,
  interlace : Int32,
) -> String? {
  if width == 0 || width > 0x7FFFFFFF || height == 0 || height > 0x7FFFFFFF {
    Some("an image of \{width}x\{height} pixels")
  } else if !is_allowed(color_type, bit_depth) {
    Some("color type \{color_type} with bit depth \{bit_depth}")
  } else if compression != 0 {
    Some("compression method \{compression}")
  } else if filter != 0 {
    Some("filter method \{filter}")
  } else if interlace > 1 {
    Some("interlace method \{interlace}")
  } else {
    None
  }
}

///|
/// The bytes of a row of `width` pixels of `bits` bits each, packed:
/// ceil(width × bits / 8), computed in 64 bits, since a row of 2^31 − 1
/// pixels of 64 bits takes more than 2^34 bytes. Raises
/// `LimitExceeded(Memory)` with that size when it is more than `limit`, so
/// the size returned always fits.
pub fn row_bytes(
  width : UInt32,
  bits : Int32,
  limit : Int32,
) -> Int32 raise @codec.CodecError {
  let needed = (width.to_uint64() * bits.to_uint64() + 7UL) / 8UL
  if needed > limit.to_uint64() {
    raise @codec.CodecError(
      LimitExceeded({
        resource: Memory,
        needed: Some(needed),
        limit: limit.to_uint64(),
      }),
      "a row of \{needed} bytes, over max_row_bytes",
    )
  }
  needed.to_int()
}

///|
/// The bytes of a row of `pixels` pixels of `bits` bits each, for a pass
/// narrower than a row whose size `row_bytes` has accepted.
pub fn pass_row_bytes(pixels : Int32, bits : Int32) -> Int32 {
  ((pixels.to_int64() * bits.to_int64() + 7L) / 8L).to_int()
}

///|
/// The first column, the first row and the steps between columns and rows
/// of each of Adam7's seven passes (8.2), and of the one pass of an image
/// that is not interlaced, last.
let pass_x0 : FixedArray[Int32] = [0, 4, 0, 2, 0, 1, 0, 0]

///|
let pass_y0 : FixedArray[Int32] = [0, 0, 4, 0, 2, 0, 1, 0]

///|
let pass_dx0 : FixedArray[Int32] = [8, 8, 4, 4, 2, 2, 1, 1]

///|
let pass_dy0 : FixedArray[Int32] = [8, 8, 8, 4, 4, 2, 2, 1]

///|
/// The passes of an image: seven when `interlaced`, else one.
pub fn passes(interlaced : Bool) -> Int32 {
  if interlaced {
    7
  } else {
    1
  }
}

///|
fn slot(interlaced : Bool, pass : Int32) -> Int32 {
  if interlaced {
    pass
  } else {
    7
  }
}

///|
/// The column of the image where pass `pass`'s pixels begin.
pub fn pass_x(interlaced : Bool, pass : Int32) -> Int32 {
  pass_x0[slot(interlaced, pass)]
}

///|
/// The row of the image where pass `pass`'s rows begin.
pub fn pass_y(interlaced : Bool, pass : Int32) -> Int32 {
  pass_y0[slot(interlaced, pass)]
}

///|
/// The distance between the columns of pass `pass`'s pixels.
pub fn pass_dx(interlaced : Bool, pass : Int32) -> Int32 {
  pass_dx0[slot(interlaced, pass)]
}

///|
/// The distance between the rows of pass `pass`.
pub fn pass_dy(interlaced : Bool, pass : Int32) -> Int32 {
  pass_dy0[slot(interlaced, pass)]
}

///|
/// The pixels of a row of pass `pass` of an image `width` pixels wide: the
/// columns `x` below `width` with `x = pass_x + i × pass_dx`. Zero for a
/// pass with none, which has no rows either, not even their filter bytes.
pub fn pass_columns(interlaced : Bool, pass : Int32, width : Int32) -> Int32 {
  let x0 = pass_x(interlaced, pass)
  if width <= x0 {
    0
  } else {
    (width - x0 - 1) / pass_dx(interlaced, pass) + 1
  }
}

///|
/// The rows of pass `pass` of an image `height` pixels high.
pub fn pass_rows(interlaced : Bool, pass : Int32, height : Int32) -> Int32 {
  let y0 = pass_y(interlaced, pass)
  if height <= y0 {
    0
  } else {
    (height - y0 - 1) / pass_dy(interlaced, pass) + 1
  }
}

///|
/// Why an fcTL's rectangle and operations do not describe a frame of an
/// image `width` x `height` (11.3.6.2), or `None` when they do: a width and
/// a height of at least 1, the rectangle inside the image, the sums taken in
/// 64 bits so that none wraps, a dispose op of 0 to 2 and a blend op of 0
/// or 1; and for the fcTL before IDAT (`first`), the whole image.
pub fn check_frame(
  width : UInt32,
  height : UInt32,
  frame_width : UInt32,
  frame_height : UInt32,
  x : UInt32,
  y : UInt32,
  dispose : Int32,
  blend : Int32,
  first~ : Bool,
) -> String? {
  if frame_width == 0 || frame_height == 0 {
    Some("a frame of \{frame_width}x\{frame_height} pixels")
  } else if x.to_uint64() + frame_width.to_uint64() > width.to_uint64() ||
    y.to_uint64() + frame_height.to_uint64() > height.to_uint64() {
    Some(
      "a frame of \{frame_width}x\{frame_height} at \{x},\{y} outside the image's \{width}x\{height}",
    )
  } else if first &&
    (x != 0 || y != 0 || frame_width != width || frame_height != height) {
    Some("the default image's frame is not the whole image")
  } else if dispose > 2 {
    Some("dispose op \{dispose}")
  } else if blend > 1 {
    Some("blend op \{blend}")
  } else {
    None
  }
}
