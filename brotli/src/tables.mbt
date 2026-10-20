// Fixed tables of RFC 7932.

///|
/// The largest alphabet: insert-and-copy length codes.
const MAX_ALPHABET : Int32 = 704

///|
const NUM_LITERALS : Int32 = 256

///|
const NUM_BLOCK_COUNT_CODES : Int32 = 26

///|
/// The order code length code lengths come in (section 3.5).
let code_length_order : FixedArray[Int32] = [
  1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15,
]

///|
/// The fixed code of code length code lengths (section 3.5), indexed by the
/// next four bits: its length and its value.
let code_length_prefix_bits : FixedArray[Int32] = [
  2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4,
]

///|
let code_length_prefix_value : FixedArray[Int32] = [
  0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5,
]

///|
/// Block count codes (section 6): base and extra bits.
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
/// Insert length codes (section 5): base and extra bits.
let insert_length_base : FixedArray[Int32] = [
  0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090,
  2114, 6210, 22594,
]

///|
let insert_length_extra : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24,
]

///|
/// Copy length codes (section 5): base and extra bits.
let copy_length_base : FixedArray[Int32] = [
  2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326,
  582, 1094, 2118,
]

///|
let copy_length_extra : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24,
]

///|
/// The insert and copy length code ranges of each 64-symbol cell of the
/// insert-and-copy alphabet (section 5).
let cell_insert_base : FixedArray[Int32] = [0, 0, 0, 0, 8, 8, 0, 16, 8, 16, 16]

///|
let cell_copy_base : FixedArray[Int32] = [0, 8, 0, 8, 0, 8, 16, 0, 16, 8, 16]

///|
/// `NDBITS` (section 8): log2 of the number of dictionary words per length.
let dictionary_size_bits : FixedArray[Int32] = [
  0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5,
  5,
]

///|
/// `DOFFSET` (section 8): where the words of each length start.
let dictionary_offsets : FixedArray[Int32] = {
  let offsets = FixedArray::make(25, 0)
  for length in 4..<24 {
    offsets[length + 1] = offsets[length] +
      (length << dictionary_size_bits[length])
  }
  offsets
}
