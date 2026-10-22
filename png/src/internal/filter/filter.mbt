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
/// each array is the filter type's place and is neither read nor written,
/// and nothing past either array's end is, whatever `len` says. Returns
/// false, changing nothing, for a type other than 0 to 4.
pub fn unfilter(
  kind : Byte,
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  len : Int32,
  unit : Int32,
) -> Bool {
  // SAFETY: every index below is at least 1, and below `end`, which is at
  // most each array's length; the left neighbours, `i - unit`, are read
  // only from `first`, where `i - unit >= 1`.
  let end = (len + 1).min(cur.length()).min(prev.length())
  let unit = unit.max(1)
  let first = (unit + 1).min(end)
  match kind {
    b'\x00' => ()
    b'\x01' =>
      for i in first..<end {
        cur.unsafe_set(i, cur.unsafe_get(i) + cur.unsafe_get(i - unit))
      }
    b'\x02' =>
      for i in 1..<end {
        cur.unsafe_set(i, cur.unsafe_get(i) + prev.unsafe_get(i))
      }
    b'\x03' => {
      for i in 1..<first {
        cur.unsafe_set(i, cur.unsafe_get(i) + (prev.unsafe_get(i) >> 1))
      }
      for i in first..<end {
        let sum = cur.unsafe_get(i - unit).to_int() +
          prev.unsafe_get(i).to_int()
        cur.unsafe_set(i, cur.unsafe_get(i) + (sum >> 1).to_byte())
      }
    }
    b'\x04' => {
      for i in 1..<first {
        cur.unsafe_set(i, cur.unsafe_get(i) + prev.unsafe_get(i))
      }
      for i in first..<end {
        let p = paeth(
          cur.unsafe_get(i - unit).to_int(),
          prev.unsafe_get(i).to_int(),
          prev.unsafe_get(i - unit).to_int(),
        )
        cur.unsafe_set(i, cur.unsafe_get(i) + p.to_byte())
      }
    }
    _ => return false
  }
  true
}
