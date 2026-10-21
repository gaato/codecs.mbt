// Decoding tables (RFC 1951 section 3.2): `@huffman.Builder` lays out the
// two-level table of a code, entries of a symbol and its code length, and
// `decorate` turns each entry into what the decoder acts on, as libdeflate's
// tables do: a literal byte, the base and extra bits of a length or a
// distance, the end of the block, a link to a second-level table, or an
// invalid code.
//
// A decorated entry is an `Int`:
// - bits 0 to 3: the code length, the bits to drop once the entry is read
//   (in a link, the root's bits; the second-level entry has the full length);
// - bits 4 to 7: the extra bits of a length or a distance, or a link's
//   second-level index bits;
// - bits 8 to 10: the kind;
// - bits 16 to 30: the literal byte, the length or distance base, or a
//   link's offset from the start of the table.

///|
const KIND_MASK : Int32 = 0x700

///|
/// A literal byte. Zero, so that `entry & KIND_MASK == 0` tests for one.
const KIND_LITERAL : Int32 = 0

///|
/// A length (literal/length code) or a distance (distance code) base.
const KIND_BASE : Int32 = 0x100

///|
const KIND_END_OF_BLOCK : Int32 = 0x200

///|
const KIND_LINK : Int32 = 0x300

///|
/// A code no symbol may use: the unused symbols 286, 287 (literal/length)
/// and 30, 31 (distance) of the fixed codes, or the half of a lone code of
/// one bit that no symbol has.
const KIND_INVALID : Int32 = 0x400

///|
/// The root of a literal/length table indexes this many bits.
const LITERAL_ROOT_BITS : Int32 = 10

///|
/// The root of a distance table, and of the code-length code's, which
/// borrows the distance table while the code lengths are read.
const DISTANCE_ROOT_BITS : Int32 = 8

///|
/// The most entries a literal/length table takes: zlib's `enough` for 288
/// symbols and a 10-bit root (a dynamic code has at most 286).
let literal_table_size : Int32 = @huffman.max_entries(
  alphabet=288,
  root_bits=LITERAL_ROOT_BITS,
).unwrap()

///|
/// The most entries a dynamic distance table takes, for 30 symbols and an
/// 8-bit root. The code-length code's table, 256 entries, fits in it.
let distance_table_size : Int32 = @huffman.max_entries(
  alphabet=30,
  root_bits=DISTANCE_ROOT_BITS,
).unwrap()

///|
/// The symbol `@huffman.Builder` gives the entries no code reaches, with a
/// code length of one bit, as zlib gives them: an incomplete code that
/// DEFLATE accepts is a lone code of one bit, or no code at all.
const UNUSED_SYMBOL : Int32 = 0xfff

///|
let unused_entry : UInt16 = ((UNUSED_SYMBOL << 4) | 1).to_uint16()

///|
/// The length bases of the literal/length symbols 257 to 285.
let length_base : FixedArray[Int32] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83,
  99, 115, 131, 163, 195, 227, 258,
]

///|
/// The extra bits of the literal/length symbols 257 to 285.
let length_extra : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5,
  5, 0,
]

///|
/// The distance bases of the distance symbols 0 to 29.
let distance_base : FixedArray[Int32] = [
  1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769,
  1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
]

///|
/// The order in which a dynamic header gives the code-length code's
/// lengths.
let code_length_order : FixedArray[Int32] = [
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
]

///|
/// What a decorated table decodes: literal/length symbols, distance
/// symbols, or the code-length code's symbols (literals of 0 to 18).
priv enum Alphabet {
  LiteralLength
  Distance
  CodeLength
}

///|
/// The decorated entry of `symbol`, coded in `length` bits.
fn symbol_entry(alphabet : Alphabet, symbol : Int32, length : Int32) -> Int32 {
  match alphabet {
    LiteralLength =>
      if symbol < 256 {
        (symbol << 16) | KIND_LITERAL | length
      } else if symbol == 256 {
        KIND_END_OF_BLOCK | length
      } else if symbol < 286 {
        (length_base[symbol - 257] << 16) |
        KIND_BASE |
        (length_extra[symbol - 257] << 4) |
        length
      } else {
        KIND_INVALID | length
      }
    Distance =>
      if symbol < 30 {
        // Symbols 0 to 3 have no extra bits, then two symbols each for 1 to
        // 13 extra bits.
        let extra = if symbol < 4 { 0 } else { (symbol >> 1) - 1 }
        (distance_base[symbol] << 16) | KIND_BASE | (extra << 4) | length
      } else {
        KIND_INVALID | length
      }
    CodeLength => (symbol << 16) | KIND_LITERAL | length
  }
}

///|
/// Turns the `size` entries `raw[0:size]` that `@huffman.Builder` built,
/// with a `1 << root_bits` root, into decorated entries in `table`.
fn decorate(
  raw : FixedArray[UInt16],
  size : Int32,
  root_bits : Int32,
  table : FixedArray[Int32],
  alphabet : Alphabet,
) -> Unit {
  let root_size = 1 << root_bits
  for i in 0..<size {
    let entry = raw[i].to_int()
    let value = entry >> 4
    let bits = entry & 15
    table[i] = if i < root_size && bits > root_bits {
      (value << 16) | KIND_LINK | ((bits - root_bits) << 4) | root_bits
    } else if value == UNUSED_SYMBOL {
      KIND_INVALID | bits
    } else {
      symbol_entry(alphabet, value, bits)
    }
  }
}

///|
/// The fixed literal/length code's table (RFC 1951 section 3.2.6), shared by
/// every decoder: 1,024 entries, its codes of at most 9 bits all in the root.
let fixed_literal_table : FixedArray[Int32] = fixed_table(
  FixedArray::makei(288, s => {
    if s < 144 {
      8
    } else if s < 256 {
      9
    } else if s < 280 {
      7
    } else {
      8
    }
  }),
  LITERAL_ROOT_BITS,
  LiteralLength,
)

///|
/// The fixed distance code's table: 32 codes of 5 bits in a root of 256
/// entries.
let fixed_distance_table : FixedArray[Int32] = fixed_table(
  FixedArray::make(32, 5),
  DISTANCE_ROOT_BITS,
  Distance,
)

///|
fn fixed_table(
  lengths : FixedArray[Int32],
  root_bits : Int32,
  alphabet : Alphabet,
) -> FixedArray[Int32] {
  let builder = @huffman.Builder(root_bits~, max_alphabet=lengths.length())
  let raw = FixedArray::make(1 << root_bits, (0 : UInt16))
  let size = builder.build(
    raw,
    0,
    lengths,
    lengths.length(),
    invalid=unused_entry,
  )
  let table = FixedArray::make(size, 0)
  decorate(raw, size, root_bits, table, alphabet)
  table
}

///|
/// What the code lengths `lengths[0:n]` make, as zlib judges a code
/// (inftrees.c): `Complete`, `Lone` for a single code of one bit, `Empty` for
/// no code at all, or `Bad` for an over-subscribed or otherwise incomplete
/// set. DEFLATE accepts a lone code or no code for the literal/length and
/// distance codes, and neither for the code-length code, except that zlib
/// reads an empty code-length code as a code of one bit for a length of
/// zero.
priv enum Shape {
  Complete
  Lone
  Empty
  Bad
}

///|
/// The verdict on the lengths `lengths[0:n]`, each 0 to 15, with `counts`
/// (16 entries) as scratch space.
fn shape(
  lengths : FixedArray[Int32],
  n : Int32,
  counts : FixedArray[Int32],
) -> Shape where {
  proof_require: shape_pre(lengths, n, counts),
  proof_ensure: result => shape_post(lengths, n, counts, result),
} {
  for l = 0; l < 16; {
    counts[l] = 0
    continue l + 1
  } where {
    proof_invariant: 0 <= l && l <= 16,
    proof_invariant: counts.length() == 16,
    proof_invariant: zero_below(counts, l),
  }
  for s = 0; s < n; {
    counts[lengths[s]] = counts[lengths[s]] + 1
    continue s + 1
  } where {
    proof_invariant: 0 <= s && s <= n,
    proof_invariant: counts.length() == 16,
    proof_invariant: @proof_codes.counted(counts, lengths, s),
  }
  // The code space left after each length: below 0 is over-subscribed (and
  // stays so), 0 at the end complete.
  let mut left = 1
  let mut longest = 0
  for l = 1; l < 16; {
    @proof_codes.space_left_step(counts, l - 1)
    left = 2 * left - counts[l]
    if counts[l] > 0 {
      longest = l
    }
    continue l + 1
  } where {
    proof_invariant: 1 <= l && l <= 16,
    proof_invariant: left == @proof_codes.space_left(counts, l - 1),
    proof_invariant: longest_upto(counts, l - 1, longest),
  }
  proof_assert left == @proof_codes.space_left(counts, 15)
  proof_assert @proof_codes.none_longer(counts, longest)
  @proof_codes.kraft_space(counts)
  if left < 0 {
    Bad
  } else if left == 0 {
    Complete
  } else if longest == 0 {
    Empty
  } else if longest == 1 {
    @proof_codes.kraft_one_bit(counts)
    proof_assert counts[1] == 1
    Lone
  } else {
    proof_assert counts[longest] > 0
    proof_assert !lone_code(counts)
    Bad
  }
}
