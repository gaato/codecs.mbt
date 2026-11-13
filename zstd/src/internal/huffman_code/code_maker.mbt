// Generated from parts/huffman/code_maker.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// Length-limited Huffman codes the way libdeflate builds them
// (deflate_make_huffman_code in deflate_compress.c, 1.24): the symbols are
// sorted by frequency, a Huffman tree is built in place, and lengths over the
// limit are pushed down to the deepest shorter length that has room. It gives
// libdeflate's codes exactly, and compares with `code_lengths` as follows:
// both are optimal when the limit does not bind, and when it does, this one
// is quicker and about as small.
//
// Every code it makes is complete and has at least two codewords: with fewer
// than two used symbols, symbol 0 and the used one (or symbol 1) get one bit
// each, so that every DEFLATE decoder accepts the code.

///|
/// The frequency is kept above the symbol in one integer.
const SYMBOL_BITS : Int32 = 10

///|
const SYMBOL_MASK : Int32 = (1 << SYMBOL_BITS) - 1

///|
/// The longest code length a code may be limited to.
const MAX_LIMIT : Int32 = 15

///|
/// Builds length-limited Huffman codes, with scratch space that every code
/// it makes reuses.
pub struct CodeMaker {
  // The symbols, sorted, and then the tree.
  priv nodes : FixedArray[Int32]
  // The sort's counters.
  priv counters : FixedArray[Int32]
  // Codewords per length, and the next codeword of each length.
  priv len_counts : FixedArray[Int32]
  priv next_codewords : FixedArray[Int32]
}

///|
/// A maker for alphabets of up to `max_alphabet` symbols (at most 1,024).
pub fn CodeMaker::CodeMaker(max_alphabet~ : Int32) -> CodeMaker {
  guard max_alphabet >= 2 && max_alphabet <= 1 << SYMBOL_BITS else {
    abort("CodeMaker: max_alphabet must be 2 to 1024")
  }
  {
    nodes: FixedArray::make(max_alphabet, 0),
    counters: FixedArray::make(max_alphabet, 0),
    len_counts: FixedArray::make(MAX_LIMIT + 1, 0),
    next_codewords: FixedArray::make(MAX_LIMIT + 1, 0),
  }
}

///|
/// The scratch space's bytes.
pub fn CodeMaker::memory_usage(self : CodeMaker) -> Int32 {
  4 *
  (
    self.nodes.length() +
    self.counters.length() +
    self.len_counts.length() +
    self.next_codewords.length()
  )
}

///|
/// Sets `lengths[0..n)` and `codes[0..n)` to a code for the frequencies
/// `freqs[0..n)`: lengths of at most `max_bits` (1 to 15, and the code must
/// fit: `n <= 1 << max_bits`), 0 for unused symbols, and the canonical
/// codewords bit-reversed, as `canonical_codes` gives them. The frequencies
/// must add up to less than `1 << 21`.
pub fn CodeMaker::make(
  self : CodeMaker,
  freqs : FixedArray[Int32],
  n : Int32,
  max_bits : Int32,
  lengths : FixedArray[Int32],
  codes : FixedArray[Int32],
) -> Unit {
  let a = self.nodes
  // Sort the used symbols by frequency, then by symbol: a counting sort on
  // the frequencies below n, the larger ones in the last counter, sorted
  // after.
  let counters = self.counters
  counters.fill(0, end=n)
  for sym in 0..<n {
    counters[freqs[sym].min(n - 1)] += 1
  }
  let mut used = 0
  for i in 1..<n {
    let count = counters[i]
    counters[i] = used
    used += count
  }
  for sym in 0..<n {
    let f = freqs[sym]
    if f != 0 {
      let k = f.min(n - 1)
      a[counters[k]] = sym | (f << SYMBOL_BITS)
      counters[k] += 1
    } else {
      lengths[sym] = 0
    }
  }
  let lo = counters[n - 2]
  let hi = counters[n - 1]
  for i in (lo + 1)..<hi {
    let v = a[i]
    let mut j = i - 1
    while j >= lo && a[j] > v {
      a[j + 1] = a[j]
      j -= 1
    }
    a[j + 1] = v
  }
  if used < 2 {
    two_codewords(freqs, n, lengths, codes)
    return
  }
  build_tree(a, used)
  let len_counts = self.len_counts
  length_counts(a, used - 2, len_counts, max_bits)
  // The longest codes go to the least frequent symbols.
  let mut i = 0
  for len = max_bits; len >= 1; len = len - 1 {
    for _ in 0..<len_counts[len] {
      lengths[a[i] & SYMBOL_MASK] = len
      i += 1
    }
  }
  let next = self.next_codewords
  next[0] = 0
  next[1] = 0
  for len in 2..<=max_bits {
    next[len] = (next[len - 1] + len_counts[len - 1]) << 1
  }
  for sym in 0..<n {
    let len = lengths[sym]
    codes[sym] = reverse_bits(next[len], len)
    next[len] += 1
  }
}

///|
/// The code of fewer than two used symbols: symbol 0 gets codeword 0 and
/// the used symbol (or symbol 1) codeword 1, both 1 bit long.
fn two_codewords(
  freqs : FixedArray[Int32],
  n : Int32,
  lengths : FixedArray[Int32],
  codes : FixedArray[Int32],
) -> Unit {
  let mut sym = 0
  for i in 0..<n {
    lengths[i] = 0
    codes[i] = 0
    if freqs[i] != 0 {
      sym = i
    }
  }
  let other = if sym != 0 { sym } else { 1 }
  codes[0] = 0
  lengths[0] = 1
  codes[other] = 1
  lengths[other] = 1
}

///|
/// Builds the Huffman tree of the `count` sorted leaves of `a` in place: the
/// internal nodes take the entries from 0, each pointing at its parent.
fn build_tree(a : FixedArray[Int32], count : Int32) -> Unit {
  let freq_mask = SYMBOL_MASK.lnot()
  let last = count - 1
  // The next leaf, the next internal node to join, and the next to make.
  let mut i = 0
  let mut b = 0
  let mut e = 0
  while true {
    let joined = if i + 1 <= last &&
      (b == e || (a[i + 1] & freq_mask) <= (a[b] & freq_mask)) {
      // Two leaves.
      let f = (a[i] & freq_mask) + (a[i + 1] & freq_mask)
      i += 2
      f
    } else if b + 2 <= e &&
      (i > last || (a[b + 1] & freq_mask) < (a[i] & freq_mask)) {
      // Two internal nodes.
      let f = (a[b] & freq_mask) + (a[b + 1] & freq_mask)
      a[b] = (e << SYMBOL_BITS) | (a[b] & SYMBOL_MASK)
      a[b + 1] = (e << SYMBOL_BITS) | (a[b + 1] & SYMBOL_MASK)
      b += 2
      f
    } else {
      // A leaf and an internal node.
      let f = (a[i] & freq_mask) + (a[b] & freq_mask)
      a[b] = (e << SYMBOL_BITS) | (a[b] & SYMBOL_MASK)
      i += 1
      b += 1
      f
    }
    a[e] = joined | (a[e] & SYMBOL_MASK)
    e += 1
    if e >= last {
      break
    }
  }
}

///|
/// Counts the codewords of each length from the tree whose root is
/// `a[root]`, pushing a leaf deeper than `max_bits` to the deepest shorter
/// length with a codeword to split.
fn length_counts(
  a : FixedArray[Int32],
  root : Int32,
  len_counts : FixedArray[Int32],
  max_bits : Int32,
) -> Unit {
  for len in 0..<=max_bits {
    len_counts[len] = 0
  }
  len_counts[1] = 2
  a[root] = a[root] & SYMBOL_MASK
  for node = root - 1; node >= 0; node = node - 1 {
    let parent = (a[node].reinterpret_as_uint() >> SYMBOL_BITS).reinterpret_as_int()
    let parent_depth = (a[parent].reinterpret_as_uint() >> SYMBOL_BITS).reinterpret_as_int()
    let depth = parent_depth + 1
    a[node] = (a[node] & SYMBOL_MASK) | (depth << SYMBOL_BITS)
    let mut len = depth
    if len >= max_bits {
      len = max_bits
      while true {
        len -= 1
        if len_counts[len] != 0 {
          break
        }
      }
    }
    len_counts[len] -= 1
    len_counts[len + 1] += 2
  }
}
