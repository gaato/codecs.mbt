///|
/// Sample `k` of byte `byte` packed with samples of `depth` bits (1, 2 or
/// 4), counting from the most significant bits (7.2): bits `8 - depth × (k +
/// 1)` up to `8 - depth × k`.
pub fn packed_sample(byte : Int32, k : Int32, depth : Int32) -> Int32 {
  @proof_bits.low_bits(@proof_bits.shr(byte, 8 - depth * (k + 1)), depth)
}

///|
/// Sample `v` of `depth` bits (1, 2, 4 or 8) on 8 bits, by repeating its
/// bits (12.4): v × 255 / (2^depth − 1), which is exact for these depths.
pub fn widen(v : Int32, depth : Int32) -> Int32 {
  if depth == 1 {
    v * 255
  } else if depth == 2 {
    v * 85
  } else if depth == 4 {
    v * 17
  } else {
    v
  }
}

///|
/// Sample `v` of 16 bits on 8, rounded to the nearest: round(v × 255 /
/// 65535).
pub fn narrow(v : Int32) -> Int32 {
  (v * 255 + 32767) / 65535
}
