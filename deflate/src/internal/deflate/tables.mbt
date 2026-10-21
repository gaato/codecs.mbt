// The symbols of RFC 1951 section 3.2.5 as the encoder uses them, laid out as
// libdeflate's deflate_compress.c lays them out: the slot of each match
// length and offset, with the base and extra bits of each slot, and the fixed
// codes of section 3.2.6.

///|
/// The literal/length alphabet, the two symbols no block uses included.
const NUM_LITLEN_SYMS : Int32 = 288

///|
const NUM_OFFSET_SYMS : Int32 = 32

///|
const NUM_PRECODE_SYMS : Int32 = 19

///|
const END_OF_BLOCK : Int32 = 256

///|
const FIRST_LEN_SYM : Int32 = 257

///|
const MIN_MATCH_LEN : Int32 = 3

///|
const MAX_MATCH_LEN : Int32 = 258

///|
/// The longest literal/length codeword: libdeflate's choice, 14 rather than
/// the 15 RFC 1951 allows, which came out smaller on Silesia and Canterbury.
const MAX_LITLEN_CODEWORD_LEN : Int32 = 14

///|
const MAX_OFFSET_CODEWORD_LEN : Int32 = 15

///|
const MAX_PRE_CODEWORD_LEN : Int32 = 7

///|
let length_slot_base : FixedArray[Int32] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
let extra_length_bits : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
let offset_slot_base : FixedArray[Int32] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
let extra_offset_bits : FixedArray[Int32] = [
  0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11,
  12, 12, 13, 13,
]

///|
/// The order the code-length code's lengths are written in.
let precode_lens_permutation : FixedArray[Int32] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

///|
let extra_precode_bits : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 7,
]

///|
/// The slot of each match length from 3 to 258.
let length_slot : FixedArray[Int32] = {
  let table = FixedArray::make(MAX_MATCH_LEN + 1, 0)
  for slot in 0..<28 {
    let base = length_slot_base[slot]
    for len in base..<(base + (1 << extra_length_bits[slot])) {
      table[len] = slot
    }
  }
  // 258 has a slot of its own, with no extra bits.
  table[MAX_MATCH_LEN] = 28
  table
}

///|
/// libdeflate's map of the offsets 1 to 256 to their slots
/// (`small_offset_slot[offset - 1]`), which `offset_slot` reuses for larger
/// offsets.
let small_offset_slot : FixedArray[Int32] = {
  let table = FixedArray::make(256, 0)
  for slot in 0..<16 {
    let base = offset_slot_base[slot]
    for offset in base..<(base + (1 << extra_offset_bits[slot])) {
      table[offset - 1] = slot
    }
  }
  table
}

///|
/// The slot of a match offset from 1 to 32,767.
#inline
fn offset_slot(offset : Int32) -> Int32 {
  if offset <= 256 {
    small_offset_slot[offset - 1]
  } else {
    small_offset_slot[(offset - 1) >> 7] + 14
  }
}

///|
/// The index of the highest set bit of a positive `x`.
#inline
fn bsr32(x : Int32) -> Int32 {
  31 - x.clz()
}

///|
/// The fixed literal/length code's lengths (section 3.2.6).
let static_litlen_lens : FixedArray[Int32] = FixedArray::makei(
  NUM_LITLEN_SYMS,
  sym => {
    if sym < 144 {
      8
    } else if sym < 256 {
      9
    } else if sym < 280 {
      7
    } else {
      8
    }
  },
)

///|
let static_litlen_codes : FixedArray[Int32] = {
  let codes = FixedArray::make(NUM_LITLEN_SYMS, 0)
  @huffman.canonical_codes(static_litlen_lens, NUM_LITLEN_SYMS, codes)
  codes
}

///|
/// The fixed distance code: 5 bits for each of the 32 symbols.
let static_offset_lens : FixedArray[Int32] = FixedArray::make(
  NUM_OFFSET_SYMS,
  5,
)

///|
let static_offset_codes : FixedArray[Int32] = {
  let codes = FixedArray::make(NUM_OFFSET_SYMS, 0)
  @huffman.canonical_codes(static_offset_lens, NUM_OFFSET_SYMS, codes)
  codes
}
