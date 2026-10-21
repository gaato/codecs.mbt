// Generated from parts/huffman/decode_table.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// Prefix-code decoding tables, as DEFLATE and Brotli decoders build them
// from code lengths (RFC 1951 section 3.2.2, RFC 7932 section 3.2): the
// two-level layout of zlib and the reference Brotli decoder.
//
// A table is a root table of `1 << root_bits` entries followed by
// second-level tables. An entry is `value << 4 | bits`:
// - in the root, `bits <= root_bits` is a symbol coded in `bits` bits, and
//   `bits > root_bits` links to a second-level table of
//   `1 << (bits - root_bits)` entries at `value` (relative to the root);
// - in a second-level table, `bits` is the full code length.
// A decoder indexes the root with the next `root_bits` bits of the stream,
// first bit lowest, and a second-level table with the bits after those.
// Entries that no code reaches (an incomplete code leaves some) hold the
// value the caller chose for them.

///|
/// The longest code length a table holds: DEFLATE's and Brotli's.
const MAX_CODE_LENGTH : Int32 = 15

///|
/// Scratch space for building tables with a `1 << root_bits`-entry root
/// over up to `max_alphabet` symbols. Reused from table to table: building
/// allocates nothing.
pub struct Builder {
  priv root_bits : Int32
  priv counts : FixedArray[Int32]
  priv next : FixedArray[Int32]
  priv sorted : FixedArray[Int32]
  priv sub_bits : FixedArray[Int32]
}

///|
/// A builder for roots of `1 << root_bits` entries (1 to 15) and alphabets
/// of up to `max_alphabet` symbols (at most 4096, what an entry holds).
pub fn Builder::Builder(root_bits~ : Int32, max_alphabet~ : Int32) -> Builder {
  guard root_bits >= 1 && root_bits <= MAX_CODE_LENGTH else {
    abort("root_bits must be 1 to 15")
  }
  guard max_alphabet >= 0 && max_alphabet <= 4096 else {
    abort("max_alphabet must be 0 to 4096")
  }
  {
    root_bits,
    counts: FixedArray::make(MAX_CODE_LENGTH + 1, 0),
    next: FixedArray::make(MAX_CODE_LENGTH + 2, 0),
    sorted: FixedArray::make(max_alphabet, 0),
    sub_bits: FixedArray::make(1 << root_bits, 0),
  }
}

///|
/// Builds the table of the code lengths `lengths[0:n]` (each 0 to 15) into
/// `table` from `base`, and returns how many entries it takes. Entries no
/// code reaches are set to `invalid`; a complete code leaves none. The
/// lengths must not over-subscribe the code space (Kraft's sum of
/// `2^-length` at most 1), and `table` must have room from `base`: both
/// abort otherwise. Which codes a format accepts (complete ones, a lone
/// symbol, an empty code) is the caller's rule.
pub fn Builder::build(
  self : Builder,
  table : FixedArray[UInt16],
  base : Int32,
  lengths : FixedArray[Int32],
  n : Int32,
  invalid~ : UInt16,
) -> Int32 {
  let root_bits = self.root_bits
  let root_size = 1 << root_bits
  let counts = self.counts
  counts.fill(0)
  for s in 0..<n {
    counts[lengths[s]] += 1
  }
  counts[0] = 0
  // The code space left after each length: below 0 is over-subscribed, 0
  // at the end complete.
  let mut left = 1
  for l in 1..<=MAX_CODE_LENGTH {
    left = (left << 1) - counts[l]
    guard left >= 0 else { abort("over-subscribed code lengths") }
  }
  // Symbols sorted by code length, then by value: the canonical order.
  let next = self.next
  next[1] = 0
  for l in 1..<MAX_CODE_LENGTH {
    next[l + 1] = next[l] + counts[l]
  }
  let sorted = self.sorted
  for s in 0..<n {
    let l = lengths[s]
    if l > 0 {
      sorted[next[l]] = s
      next[l] += 1
    }
  }
  // First pass: the longest code under each root entry sizes its subtable.
  let sub_bits = self.sub_bits
  sub_bits.fill(0)
  let mut code = 0
  for l in 1..<=MAX_CODE_LENGTH {
    for _ in 0..<counts[l] {
      if l > root_bits {
        sub_bits[reverse_bits(code, l) & (root_size - 1)] = l - root_bits
      }
      code += 1
    }
    code = code << 1
  }
  let mut size = root_size
  for r in 0..<root_size {
    if sub_bits[r] > 0 {
      size += 1 << sub_bits[r]
    }
  }
  guard base >= 0 && base + size <= table.length() else {
    abort("no room for the table")
  }
  if left > 0 {
    table.fill(invalid, start=base, end=base + size)
  }
  let mut offset = root_size
  for r in 0..<root_size {
    if sub_bits[r] > 0 {
      table[base + r] = ((offset << 4) | (sub_bits[r] + root_bits)).to_uint16()
      offset += 1 << sub_bits[r]
    }
  }
  // Second pass: fill the entries.
  code = 0
  let mut index = 0
  for l in 1..<=MAX_CODE_LENGTH {
    for _ in 0..<counts[l] {
      let entry = ((sorted[index] << 4) | l).to_uint16()
      index += 1
      let rev = reverse_bits(code, l)
      if l <= root_bits {
        for i = rev; i < root_size; i = i + (1 << l) {
          table[base + i] = entry
        }
      } else {
        let link = table[base + (rev & (root_size - 1))].to_int()
        let start = base + (link >> 4)
        let span = 1 << ((link & 15) - root_bits)
        for i = rev >> root_bits; i < span; i = i + (1 << (l - root_bits)) {
          table[start + i] = entry
        }
      }
      code += 1
    }
    code = code << 1
  }
  size
}
