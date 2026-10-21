// Arithmetic that overflows for some inputs: with machine integers, `moon
// prove` must refuse it.

///|
/// Overflows for `a + b` past 2^32 - 1.
pub fn add_u32(
  a : UInt32,
  b : UInt32,
) -> UInt32 where {
  proof_ensure: result => result >= a,
} {
  a + b
}

///|
/// Overflows past 2^31 - 1.
pub fn double(
  x : Int32,
) -> Int32 where {
  proof_require: 0 <= x,
  proof_ensure: result => result >= x,
} {
  x * 2
}
