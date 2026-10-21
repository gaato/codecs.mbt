///|
/// The modulus of both sums: the largest prime below 2^16.
const BASE : UInt32 = 65521

///|
/// The most bytes whose sums fit in 32 bits before reducing them (zlib's
/// NMAX): 255 n (n + 1) / 2 + (n + 1) (BASE - 1) <= 2^32 - 1.
const NMAX : Int32 = 5552

///|
/// The Adler-32 of no data.
pub const INITIAL : UInt32 = 1

///|
/// The Adler-32 of the data so far, `adler`, extended by `data`.
pub fn update(adler : UInt32, data : ArrayView[Byte]) -> UInt32 {
  let mut a = adler & 0xFFFF
  let mut b = adler >> 16
  let mut i = 0
  while i < data.length() {
    let end = (i + NMAX).min(data.length())
    for j in i..<end {
      a = a + data[j].to_uint()
      b = b + a
    }
    a = a % BASE
    b = b % BASE
    i = end
  }
  (b << 16) | a
}

///|
/// The Adler-32 of `data`.
pub fn of_bytes(data : BytesView) -> UInt32 {
  update(INITIAL, data.to_array()[:])
}
