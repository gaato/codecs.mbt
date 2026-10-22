///|
/// The bytes of a row of `width` pixels of `bits` bits each, packed:
/// ceil(width × bits / 8), when that is at most `limit`; else -1. Computed
/// without the product, which passes 2^31 for wide rows of deep pixels, and
/// for each of the nine pixel sizes with its own constant, so that each case
/// is linear arithmetic.
pub fn row_size(
  width : Int32,
  bits : Int32,
  limit : Int32,
) -> Int32 where {
  proof_require: row_pre(width, bits, limit),
  proof_ensure: result => row_post(width, bits, limit, result),
} {
  if bits == 1 {
    within(width / 8 + (if width % 8 == 0 { 0 } else { 1 }), limit)
  } else if bits == 2 {
    within(width / 4 + (if width % 4 == 0 { 0 } else { 1 }), limit)
  } else if bits == 4 {
    within(width / 2 + (if width % 2 == 0 { 0 } else { 1 }), limit)
  } else if bits == 8 {
    within(width, limit)
  } else if bits == 16 {
    if width > limit / 2 {
      -1
    } else {
      proof_assert int32(width * 2)
      width * 2
    }
  } else if bits == 24 {
    if width > limit / 3 {
      -1
    } else {
      proof_assert int32(width * 3)
      width * 3
    }
  } else if bits == 32 {
    if width > limit / 4 {
      -1
    } else {
      proof_assert int32(width * 4)
      width * 4
    }
  } else if bits == 48 {
    if width > limit / 6 {
      -1
    } else {
      proof_assert int32(width * 6)
      width * 6
    }
  } else if width > limit / 8 {
    -1
  } else {
    proof_assert int32(width * 8)
    width * 8
  }
}

///|
/// `n` when it is at most `limit`, else -1.
fn within(
  n : Int32,
  limit : Int32,
) -> Int32 where {
  proof_require: 0 <= n && 0 <= limit,
  proof_ensure: result => within_post(n, limit, result),
} {
  if n > limit {
    -1
  } else {
    n
  }
}

///|
/// Whether a frame of `frame_width` x `frame_height` at `x`, `y` lies inside
/// an image `width` x `height`: x + frame_width ≤ width and y + frame_height
/// ≤ height. The values are fcTL's and IHDR's 32-bit fields, so the sums are
/// taken in 64 bits, where they cannot wrap.
pub fn frame_inside(
  width : Int64,
  height : Int64,
  frame_width : Int64,
  frame_height : Int64,
  x : Int64,
  y : Int64,
) -> Bool where {
  proof_require: fields_pre(width, height, frame_width, frame_height, x, y),
  proof_ensure: result => {
    result == inside(width, height, frame_width, frame_height, x, y)
  },
} {
  proof_assert sum_fits(x, frame_width) && sum_fits(y, frame_height)
  x + frame_width <= width && y + frame_height <= height
}
