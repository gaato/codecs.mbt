///|
/// The column of the image where Adam7's pass `pass` (0 to 6) begins: 0, 4,
/// 0, 2, 0, 1, 0 (8.2).
pub fn adam7_x(pass : Int32) -> Int32 {
  @rules.pass_x(true, pass)
}

///|
/// The row of the image where Adam7's pass `pass` begins: 0, 0, 4, 0, 2, 0,
/// 1.
pub fn adam7_y(pass : Int32) -> Int32 {
  @rules.pass_y(true, pass)
}

///|
/// The distance between the columns of Adam7's pass `pass`: 8, 8, 4, 4, 2,
/// 2, 1.
pub fn adam7_dx(pass : Int32) -> Int32 {
  @rules.pass_dx(true, pass)
}

///|
/// The distance between the rows of Adam7's pass `pass`: 8, 8, 8, 4, 4, 2,
/// 2.
pub fn adam7_dy(pass : Int32) -> Int32 {
  @rules.pass_dy(true, pass)
}

///|
/// The pixels of a row of Adam7's pass `pass` in an image `width` pixels
/// wide; 0 when the pass has none, and then no rows either.
pub fn adam7_columns(pass : Int32, width : Int32) -> Int32 {
  @rules.pass_columns(true, pass, width)
}

///|
/// The rows of Adam7's pass `pass` in an image `height` pixels high.
pub fn adam7_rows(pass : Int32, height : Int32) -> Int32 {
  @rules.pass_rows(true, pass, height)
}

///|
/// Puts the `pixels` pixels of `row`, a row of a pass in PNG's layout
/// (`bits` bits a pixel: the channels times the bit depth), into `into`, a
/// row of the image in the same layout: pixel `i` goes to column `x + i ×
/// dx`. The pass's lattice is what `Decoder::pass_x` and `Decoder::pass_dx`
/// report after `Rows`. Pixels packed below 8 bits are put bit by bit, and
/// the other bits of `into` are kept.
pub fn scatter(
  row : ArrayView[Byte],
  pixels : Int32,
  bits : Int32,
  x : Int32,
  dx : Int32,
  into : MutArrayView[Byte],
) -> Unit {
  if bits >= 8 {
    let n = bits / 8
    for i in 0..<pixels {
      let to = (x + i * dx) * n
      for b in 0..<n {
        into[to + b] = row[i * n + b]
      }
    }
    return
  }
  let per_byte = 8 / bits
  let mask = (1 << bits) - 1
  for i in 0..<pixels {
    let v = @convert.packed_sample(
      row[i / per_byte].to_int(),
      i % per_byte,
      bits,
    )
    let column = x + i * dx
    let shift = 8 - bits * (column % per_byte + 1)
    let at = column / per_byte
    into[at] = ((into[at].to_int() & (mask << shift).lnot()) | (v << shift)).to_byte()
  }
}
