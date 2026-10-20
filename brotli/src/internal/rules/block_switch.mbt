// Block switch commands (RFC 7932 section 6).

///|
/// Block count codes: base and extra bits.
let block_count_base : FixedArray[Int32] = [
  1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369,
  497, 753, 1265, 2289, 4337, 8433, 16625,
]

///|
let block_count_extra : FixedArray[Int32] = [
  2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13,
  24,
]

///|
/// The number of block count codes.
pub const NUM_BLOCK_COUNT_CODES : Int32 = 26

///|
/// How many extra bits follow block count code `code` (0 to 25).
pub fn block_count_extra_bits(code : Int32) -> Int32 {
  block_count_extra[code]
}

///|
/// The block count of block count code `code` (0 to 25) with the value
/// `extra` of its extra bits.
pub fn block_count(code : Int32, extra : Int32) -> Int32 {
  block_count_base[code] + extra
}

///|
/// The block type that block type code `code` switches to, among `types`
/// block types, where `current` is the current block type and `previous`
/// the one before it: 0 names `previous`, 1 the type after `current`, and
/// `2 + t` type `t`, all modulo `types`. The codes range over 0 to
/// `types + 1`, and both types over 0 to `types - 1`.
pub fn next_block_type(
  code : Int32,
  current~ : Int32,
  previous~ : Int32,
  types~ : Int32,
) -> Int32 {
  let t = match code {
    0 => previous
    1 => current + 1
    _ => code - 2
  }
  if t >= types {
    t - types
  } else {
    t
  }
}
