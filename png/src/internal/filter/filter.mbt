///|
/// The Paeth predictor (9.4): of `a` (left), `b` (above) and `c` (above
/// left), the one closest to `a + b - c`, ties going to `a`, then `b`.
pub fn paeth(a : Int32, b : Int32, c : Int32) -> Int32 {
  let p = a + b - c
  let pa = (p - a).abs()
  let pb = (p - b).abs()
  let pc = (p - c).abs()
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// Reverses filter type `kind` on the row in `cur[1:len + 1]`, in place,
/// against the row above in `prev[1:len + 1]` (zeros for the first row of a
/// pass). `unit` is the bytes of a whole pixel, at least 1: the distance to
/// the byte on the left, which is 0 for the first `unit` bytes. Byte 0 of
/// each array is the filter type's place and is neither read nor written.
/// Returns false, changing nothing, for a type other than 0 to 4.
pub fn unfilter(
  kind : Byte,
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  len : Int32,
  unit : Int32,
) -> Bool {
  let first = (unit + 1).min(len + 1)
  match kind {
    b'\x00' => ()
    b'\x01' =>
      for i in (unit + 1)..<(len + 1) {
        cur[i] = cur[i] + cur[i - unit]
      }
    b'\x02' =>
      for i in 1..<(len + 1) {
        cur[i] = cur[i] + prev[i]
      }
    b'\x03' => {
      for i in 1..<first {
        cur[i] = cur[i] + (prev[i] >> 1)
      }
      for i in first..<(len + 1) {
        let sum = cur[i - unit].to_int() + prev[i].to_int()
        cur[i] = cur[i] + (sum >> 1).to_byte()
      }
    }
    b'\x04' => {
      for i in 1..<first {
        cur[i] = cur[i] + prev[i]
      }
      for i in first..<(len + 1) {
        let p = paeth(
          cur[i - unit].to_int(),
          prev[i].to_int(),
          prev[i - unit].to_int(),
        )
        cur[i] = cur[i] + p.to_byte()
      }
    }
    _ => return false
  }
  true
}
