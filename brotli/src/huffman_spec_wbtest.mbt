// The decoding tables of `Group::build` and `Group::single` against RFC 7932 section 3.2 (the
// canonical codes of RFC 1951 section 3.2.2): code lengths to prefix codes,
// written out the way the RFCs explain them rather than the way the builder
// computes them.

///|
/// The canonical code of each symbol of `lengths`, most significant bit
/// first, or -1 for an unused symbol (RFC 1951 section 3.2.2).
fn canonical_reference(lengths : Array[Int32]) -> Array[Int32] {
  let count = Array::make(16, 0)
  for l in lengths {
    if l > 0 {
      count[l] += 1
    }
  }
  let next = Array::make(16, 0)
  let mut code = 0
  for bits in 1..<16 {
    code = (code + count[bits - 1]) << 1
    next[bits] = code
  }
  [
    for l in lengths => {
      if l == 0 {
        -1
      } else {
        next[l] += 1
        next[l] - 1
      }
    }
  ]
}

///|
/// The symbols by code: `length << 16 | code` to symbol.
fn code_index(
  lengths : Array[Int32],
  codes : Array[Int32],
) -> Map[Int32, Int32] {
  let index = Map([])
  for s, l in lengths {
    if l > 0 {
      index[(l << 16) | codes[s]] = s
    }
  }
  index
}

///|
/// The symbol whose code starts the bit sequence `bits` (read least
/// significant bit first, as the decoder reads the stream) and that code's
/// length; `None` when no code does.
fn decode_reference(index : Map[Int32, Int32], bits : Int32) -> (Int32, Int32)? {
  // The first `l` bits of the stream, most significant first.
  for l = 1, first = bits & 1; l <= MAX_CODE_LENGTH; {
    if index.get((l << 16) | first) is Some(s) {
      return Some((s, l))
    }
    continue l + 1, (first << 1) | ((bits >> l) & 1)
  }
  None
}

///|
/// Whether no code of `lengths` and `codes` is a prefix of another.
fn prefix_free(lengths : Array[Int32], codes : Array[Int32]) -> Bool {
  for a, la in lengths {
    for b, lb in lengths {
      if a != b && la > 0 && lb > 0 && la <= lb {
        if codes[b] >> (lb - la) == codes[a] {
          return false
        }
      }
    }
  }
  true
}

///|
/// The entry tree `tree` of `group` decodes the bit sequence `bits` to, as
/// `Decoder::read_symbol` looks it up: the symbol and its code length.
fn table_lookup(group : Group, tree : Int32, bits : Int32) -> (Int32, Int32) {
  let pool = group.pool
  let base = group.offsets[tree]
  let mut entry = pool[base + (bits & (ROOT_SIZE - 1))].to_int()
  let mut n = entry & 15
  if n > ROOT_BITS {
    let sub = (bits >> ROOT_BITS) & ((1 << (n - ROOT_BITS)) - 1)
    entry = pool[base + (entry >> 4) + sub].to_int()
    n = entry & 15
  }
  (entry >> 4, n)
}

///|
/// Builds `lengths` into a fresh group as the decoder does: a lone symbol
/// takes no bits.
fn build_lengths(builder : @huffman.Builder, lengths : Array[Int32]) -> Group {
  let n = lengths.length()
  let fixed = FixedArray::make(MAX_ALPHABET, 0)
  for s, l in lengths {
    fixed[s] = l
  }
  let group = Group::new(1)
  group.reset(1, n)
  if [ for s, l in lengths if l > 0 => s ] is [symbol] {
    group.single(0, symbol)
  } else {
    group.build(builder, 0, fixed, n)
  }
  group
}

///|
/// Checks the table built from the lengths of a complete code (two or more
/// symbols) against the reference: every bit sequence decodes to the
/// symbol whose canonical code starts it, the root links to second-level
/// tables that tile the rest of the table, each as small as its codes
/// allow, and the table is within its bound.
fn check_table(
  builder : @huffman.Builder,
  lengths : Array[Int32],
) -> Unit raise {
  let codes = canonical_reference(lengths)
  guard prefix_free(lengths, codes) else { fail("\{Repr(lengths)}") }
  let group = build_lengths(builder, lengths)
  let index = code_index(lengths, codes)
  let longest = lengths.fold(init=0, (m, l) => m.max(l))
  // Sequences of the longest code's length cover every code.
  for bits in 0..<(1 << longest) {
    let expected = decode_reference(index, bits)
    if Some(table_lookup(group, 0, bits)) != expected {
      fail("\{Repr(lengths)}: bits \{bits}")
    }
  }
  // The second-level tables: one per root entry whose codes are longer than
  // the root, sized by the longest of them, laid out after the root in
  // order and covering the table.
  let size = group.used - group.offsets[0]
  // The longest code under each root entry: the entry its first bits pick.
  let deepest = Array::make(ROOT_SIZE, 0)
  for s, l in lengths {
    if l > ROOT_BITS {
      let r = @huffman.reverse_bits(codes[s], l) % ROOT_SIZE
      deepest[r] = deepest[r].max(l)
    }
  }
  let mut offset = ROOT_SIZE
  for r in 0..<ROOT_SIZE {
    let entry = group.pool[group.offsets[0] + r].to_int()
    let deepest = deepest[r]
    if deepest == 0 {
      assert_true(entry % 16 <= ROOT_BITS)
    } else {
      assert_eq(entry % 16, deepest)
      assert_eq(entry >> 4, offset)
      offset += 1 << (deepest - ROOT_BITS)
    }
  }
  assert_eq(offset, size)
  assert_true(size <= max_table_size(lengths.length()))
}

///|
/// Whether `lengths` (each 0 to 15) are those of a complete prefix code:
/// Kraft's sum of `2^-length` is exactly 1.
fn complete(lengths : Array[Int32]) -> Bool {
  lengths.fold(init=0, (sum, l) => if l > 0 { sum + (32768 >> l) } else { sum }) ==
  32768
}

///|
/// Random lengths of a complete prefix code over `alphabet` symbols: a tree
/// grown by splitting random leaves no deeper than 15, its leaves given to
/// random symbols.
fn random_complete(rng : Rng, alphabet : Int32) -> Array[Int32] {
  let leaves = rng.below(alphabet - 1) + 2
  let depths = [0]
  for tries = 0
      depths.length() < leaves && tries < 4 * leaves
      tries = tries + 1 {
    let i = rng.below(depths.length())
    // Deep splits now and then, so that second-level tables come out.
    let i = if rng.below(4) == 0 {
      depths
      .search_by(d => d == depths.fold(init=0, (m, d) => m.max(d)))
      .unwrap()
    } else {
      i
    }
    if depths[i] < MAX_CODE_LENGTH {
      let d = depths[i] + 1
      depths[i] = d
      depths.push(d)
    }
  }
  let lengths = Array::make(alphabet, 0)
  let slots = [ for s in 0..<alphabet => s ]
  for i in 0..<depths.length() {
    let j = i + rng.below(alphabet - i)
    let tmp = slots[i]
    slots[i] = slots[j]
    slots[j] = tmp
    lengths[slots[i]] = depths[i]
  }
  lengths
}

///|
test "Builder::build: RFC 1951's example" {
  // Symbols A to H with lengths 3, 3, 3, 3, 3, 2, 4, 4: codes 010, 011,
  // 100, 101, 110, 00, 1110, 1111.
  let lengths = [3, 3, 3, 3, 3, 2, 4, 4]
  debug_inspect(
    canonical_reference(lengths),
    content="[2, 3, 4, 5, 6, 0, 14, 15]",
  )
  let builder = table_builder()
  check_table(builder, lengths)
  let group = build_lengths(builder, lengths)
  // 1110 comes first in the stream as 0, 1, 1, 1: the bit sequence 0b0111.
  debug_inspect(table_lookup(group, 0, 0b0111), content="(6, 4)")
  debug_inspect(table_lookup(group, 0, 0b00), content="(5, 2)")
}

///|
test "Builder::build: every complete code of up to 4 symbols" {
  let builder = table_builder()
  let mut checked = 0
  for n in 2..<=4 {
    for i in 0..<(1 << (4 * n)) {
      let lengths = [ for k in 0..<n => (i >> (4 * k)) & 15 ]
      if complete(lengths) {
        check_table(builder, lengths)
        checked += 1
      }
    }
  }
  // Over 2, 3 and 4 symbols, some unused: lengths 1, 1 (1, 3 and 6 ways),
  // 1, 2, 2 (3 and 12 ways), 1, 2, 3, 3 (12 ways) and 2, 2, 2, 2 (1 way).
  inspect(checked, content="38")
}

///|
test "Builder::build: every shape of complete code with codes up to 15 bits" {
  // Every count of codes per length, for up to 16 codes: the shapes of
  // complete codes, each over the first symbols of a 20-symbol alphabet.
  let builder = table_builder()
  let counts = Array::make(16, 0)
  let mut shapes = 0
  fn walk(len : Int32, room : Int32, used : Int32) -> Unit raise {
    // `room` is the unfilled share of the code space, in units of 2^-len.
    if room == 0 {
      let lengths = Array::make(20, 0)
      let mut s = 0
      for l in 1..<=15 {
        for _ in 0..<counts[l] {
          lengths[s] = l
          s += 1
        }
      }
      check_table(builder, lengths)
      shapes += 1
      return
    }
    guard len <= MAX_CODE_LENGTH && room <= 16 - used else { return }
    for c = room.min(16 - used); c >= 0; c = c - 1 {
      counts[len] = c
      walk(len + 1, (room - c) * 2, used + c)
    }
    counts[len] = 0
  }
  walk(1, 2, 0)
  inspect(
    shapes,
    content=(
      #|3711
    ),
  )
}

///|
test "Builder::build: random complete codes match the reference" {
  let rng = Rng::new(1951)
  let builder = table_builder()
  for i in 0..<200 {
    let alphabet = [18, 26, 256, 704][i % 4]
    let lengths = random_complete(rng, alphabet)
    assert_true(complete(lengths))
    check_table(builder, lengths)
  }
}

///|
test "Builder::build: a one-symbol code takes no bits" {
  let builder = table_builder()
  for symbol in [0, 5, 703] {
    let lengths = Array::make(704, 0)
    lengths[symbol] = 1
    let group = build_lengths(builder, lengths)
    for bits in 0..<(1 << 15) {
      assert_eq(table_lookup(group, 0, bits), (symbol, 0))
    }
    assert_eq(group.used, ROOT_SIZE)
  }
}
