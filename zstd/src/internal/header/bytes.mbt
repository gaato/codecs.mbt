// Reading header fields from bytes. Bytes past the end read as zero, so the
// parsers are total; the decoder only ever passes headers it has gathered
// whole, and no result depends on a byte past the end.

///|
/// The byte at `data[at]` as an `Int`, or 0 past either end of `data`.
pub fn byte_at(data : ArrayView[Byte], at : Int32) -> Int32 {
  match data.get(at) {
    Some(b) => b.to_int()
    None => 0
  }
}

///|
/// The little-endian value of `n` bytes from `data[at]`, `n` at most 8.
fn le(data : ArrayView[Byte], at : Int32, n : Int32) -> UInt64 {
  for i = n - 1, v = 0UL; i >= 0; {
    continue i - 1, (v << 8) | byte_at(data, at + i).to_uint64()
  } nobreak {
    v
  }
}
