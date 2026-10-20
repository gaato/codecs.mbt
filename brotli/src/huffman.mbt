// Prefix-code decoding tables (RFC 7932 section 3).
//
// A table is an 8-bit root table followed by second-level tables, the layout
// of the reference decoder. An entry is `value << 4 | bits`:
// - in the root, `bits <= 8` is a symbol coded in `bits` bits, and
//   `bits > 8` links to a second-level table of `1 << (bits - 8)` entries at
//   `value` (relative to the root);
// - in a second-level table, `bits` (9..15) is the full code length.
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
/// Scratch space for building tables, shared by every group of a decoder.
priv struct Builder {
  counts : FixedArray[Int32]
  next : FixedArray[Int32]
  sorted : FixedArray[Int32]
  sub_bits : FixedArray[Int32]
}

///|
fn Builder::new() -> Builder {
  {
    counts: FixedArray::make(MAX_CODE_LENGTH + 1, 0),
    next: FixedArray::make(MAX_CODE_LENGTH + 2, 0),
    sorted: FixedArray::make(MAX_ALPHABET, 0),
    sub_bits: FixedArray::make(ROOT_SIZE, 0),
  }
}

///|
/// `code`'s low `length` bits in reverse order: prefix codes are packed most
/// significant bit first into a least-significant-bit-first stream.
fn reverse_bits(code : Int32, length : Int32) -> Int32 {
  for i = 0, c = code, r = 0; i < length; {
    continue i + 1, c >> 1, (r << 1) | (c & 1)
  } nobreak {
    r
  }
}

///|
/// Builds tree `tree` of `group` from the code lengths `lengths[0:n]`.
/// The caller has checked that the lengths form a complete code, or name
/// exactly one symbol.
fn Builder::build(
  self : Builder,
  group : Group,
  tree : Int32,
  lengths : FixedArray[Int32],
  n : Int32,
) -> Unit {
  let counts = self.counts
  counts.fill(0)
  let mut used = 0
  let mut last = 0
  for s in 0..<n {
    let l = lengths[s]
    if l > 0 {
      counts[l] += 1
      used += 1
      last = s
    }
  }
  let base = group.used
  group.offsets[tree] = base
  if used == 1 {
    group.reserve(ROOT_SIZE)
    group.pool.fill((last << 4).to_uint16(), start=base, end=base + ROOT_SIZE)
    group.used = base + ROOT_SIZE
    return
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
      if l > ROOT_BITS {
        sub_bits[reverse_bits(code, l) & (ROOT_SIZE - 1)] = l - ROOT_BITS
      }
      code += 1
    }
    code = code << 1
  }
  let mut size = ROOT_SIZE
  for r in 0..<ROOT_SIZE {
    if sub_bits[r] > 0 {
      size += 1 << sub_bits[r]
    }
  }
  group.reserve(size)
  let pool = group.pool
  let mut offset = ROOT_SIZE
  for r in 0..<ROOT_SIZE {
    if sub_bits[r] > 0 {
      pool[base + r] = ((offset << 4) | (sub_bits[r] + ROOT_BITS)).to_uint16()
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
      if l <= ROOT_BITS {
        for i = rev; i < ROOT_SIZE; i = i + (1 << l) {
          pool[base + i] = entry
        }
      } else {
        let link = pool[base + (rev & (ROOT_SIZE - 1))].to_int()
        let start = base + (link >> 4)
        let span = 1 << ((link & 15) - ROOT_BITS)
        for i = rev >> ROOT_BITS; i < span; i = i + (1 << (l - ROOT_BITS)) {
          pool[start + i] = entry
        }
      }
      code += 1
    }
    code = code << 1
  }
  group.used = base + size
}
