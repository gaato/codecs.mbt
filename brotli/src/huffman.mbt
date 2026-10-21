// Prefix-code decoding tables (RFC 7932 section 3), built by `@huffman.Builder` with
// an 8-bit root, the layout of the reference decoder: an entry is
// `value << 4 | bits`, a symbol coded in `bits` bits or, in the root with
// `bits > 8`, a link to a second-level table (see `@huffman.Builder`).
// A one-symbol code has `bits = 0`: the symbol takes no bits at all.

///|
const ROOT_BITS : Int32 = 8

///|
const ROOT_SIZE : Int32 = 256

///|
/// The longest code length RFC 7932 allows.
const MAX_CODE_LENGTH : Int32 = 15

///|
/// The tables of one group of prefix codes (all literal codes, say), packed
/// into one growing pool. `offsets[i]` is where tree `i` starts.
priv struct Group {
  mut pool : FixedArray[UInt16]
  mut used : Int32
  offsets : FixedArray[Int32]
}

///|
fn Group::new(trees : Int32) -> Group {
  {
    pool: FixedArray::make(0, 0),
    used: 0,
    offsets: FixedArray::make(trees, 0),
  }
}

///|
/// The most entries one table over `alphabet` symbols takes: the reference
/// decoder's bound (alphabet + 376, from zlib's `enough`).
fn max_table_size(alphabet : Int32) -> Int32 {
  alphabet + 376
}

///|
/// Forgets every table, keeping the pool for the next meta-block, and makes
/// room for `trees` tables over `alphabet` symbols.
fn Group::reset(self : Group, trees : Int32, alphabet : Int32) -> Unit {
  self.used = 0
  self.reserve(trees * max_table_size(alphabet))
}

///|
/// Makes room for `size` more entries.
fn Group::reserve(self : Group, size : Int32) -> Unit {
  let need = self.used + size
  guard need > self.pool.length() else { return }
  let grown = FixedArray::make(need, (0 : UInt16))
  FixedArray::unsafe_blit(grown, 0, self.pool, 0, self.used)
  self.pool = grown
}

///|
/// A builder for every table of a decoder: 8-bit roots, alphabets up to
/// the largest.
fn table_builder() -> @huffman.Builder {
  @huffman.Builder(root_bits=ROOT_BITS, max_alphabet=MAX_ALPHABET)
}

///|
/// Builds tree `tree` from the code lengths `lengths[0:n]`, which the caller
/// has checked form a complete code of two or more symbols.
fn Group::build(
  self : Group,
  builder : @huffman.Builder,
  tree : Int32,
  lengths : FixedArray[Int32],
  n : Int32,
) -> Unit {
  let base = self.used
  self.offsets[tree] = base
  self.reserve(max_table_size(n))
  // A complete code leaves no entry for `invalid`.
  self.used = base + builder.build(self.pool, base, lengths, n, invalid=0)
}

///|
/// Makes tree `tree` the code of the one symbol `symbol`, which takes no
/// bits.
fn Group::single(self : Group, tree : Int32, symbol : Int32) -> Unit {
  let base = self.used
  self.offsets[tree] = base
  self.reserve(ROOT_SIZE)
  self.pool.fill((symbol << 4).to_uint16(), start=base, end=base + ROOT_SIZE)
  self.used = base + ROOT_SIZE
}
