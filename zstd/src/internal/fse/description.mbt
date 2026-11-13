// Writing a table description (RFC 8878 section 4.1.1): the inverse of the
// decoder's `Fse::read`.

///|
/// Writes the description of `norm[0:count]`, a distribution over
/// `1 << log` states that ends with a symbol of nonzero probability, as
/// `normalize` gives it, into `out`, which is at a byte boundary, and pads it
/// to the next byte boundary as the decoder expects.
///
/// Each probability `p` goes in as `p + 1`, in as few bits as the states
/// still unassigned allow: the values `0..=remaining + 1` take `width` bits
/// (the bits of `remaining + 1`), but the smallest of them one bit fewer,
/// as many as the `width`-bit numbers above `remaining + 1` would waste.
/// After each 0, two-bit flags say how many more 0s follow: 3 means three
/// and another flag.
pub fn write_description(
  out : @bits.BitPacker,
  norm : FixedArray[Int32],
  count : Int32,
  log : Int32,
) -> Unit {
  out.write(4, log - MIN_LOG)
  let mut remaining = 1 << log
  let mut s = 0
  while remaining > 0 && s < count {
    let p = norm[s]
    let value = p + 1
    let width = 32 - (remaining + 1).clz()
    let low_mask = (1 << (width - 1)) - 1
    // The values below `short` take `width - 1` bits.
    let short = (1 << width) - 1 - (remaining + 1)
    if value < short {
      out.write(width - 1, value)
    } else if value <= low_mask {
      out.write(width, value)
    } else {
      out.write(width, value + short)
    }
    remaining -= if p < 0 { 1 } else { p }
    s += 1
    if p == 0 {
      let mut run = 0
      while s + run < count && norm[s + run] == 0 {
        run += 1
      }
      s += run
      while run >= 3 {
        out.write(2, 3)
        run -= 3
      }
      out.write(2, run)
    }
  }
  out.align()
}
