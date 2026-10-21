// Generated from parts/huffman/decode_table_spec_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// Specifications of the decoding tables: every bit sequence decodes to the
// symbol whose canonical code (RFC 1951 section 3.2.2, `reference_canonical`)
// starts it, entries no code reaches hold the caller's value, and the layout
// is the two-level one with tables as small as zlib's.

///|
/// The value the tests give entries that no code reaches.
const INVALID : UInt16 = 0xfff0

///|
/// The table of `lengths` with a `1 << root_bits` root, and the entries it
/// takes.
fn built(
  root_bits : Int32,
  lengths : FixedArray[Int32],
) -> (FixedArray[UInt16], Int32) {
  let builder = @huffman.Builder(root_bits~, max_alphabet=lengths.length())
  // Room for the largest table, behind a few entries of something else.
  let table = FixedArray::make(3 + (1 << 16), (1 : UInt16))
  let size = builder.build(table, 3, lengths, lengths.length(), invalid=INVALID)
  (table, size)
}

///|
/// The entry a decoder reaches for the bit sequence `bits` (first bit
/// lowest), looking it up as the tables' layout says.
fn lookup(
  table : FixedArray[UInt16],
  root_bits : Int32,
  bits : Int32,
) -> UInt16 {
  let entry = table[3 + (bits & ((1 << root_bits) - 1))]
  let n = entry.to_int() & 15
  if entry != INVALID && n > root_bits {
    let sub = (bits >> root_bits) & ((1 << (n - root_bits)) - 1)
    table[3 + (entry.to_int() >> 4) + sub]
  } else {
    entry
  }
}

///|
/// The entry the code that starts `bits` should have, `INVALID` if none.
fn expected_entry(index : Map[Int32, Int32], bits : Int32) -> UInt16 {
  // The first `l` bits of the stream, most significant first.
  for l = 1, first = bits & 1; l <= 15; {
    if index.get((l << 16) | first) is Some(s) {
      return ((s << 4) | l).to_uint16()
    }
    continue l + 1, (first << 1) | ((bits >> l) & 1)
  }
  INVALID
}

///|
/// Checks the table of `lengths` (not over-subscribed) with a
/// `1 << root_bits` root against the canonical codes, and its layout:
/// second-level tables, one per root entry whose codes are longer than the
/// root, sized by the longest of them and laid out after the root in order.
/// The entries it takes.
fn check(root_bits : Int32, lengths : FixedArray[Int32]) -> Int32 raise {
  let codes = reference_canonical(lengths)
  let index : Map[Int32, Int32] = Map([])
  let deepest = Array::make(1 << root_bits, 0)
  for s, l in lengths {
    if l > 0 {
      index[(l << 16) | codes[s]] = s
      if l > root_bits {
        let r = @huffman.reverse_bits(codes[s], l) & ((1 << root_bits) - 1)
        deepest[r] = deepest[r].max(l)
      }
    }
  }
  let (table, size) = built(root_bits, lengths)
  // Sequences as long as the longest code, or the root, cover every entry.
  let longest = lengths.fold(init=root_bits, (m, l) => m.max(l))
  for bits in 0..<(1 << longest) {
    if lookup(table, root_bits, bits) != expected_entry(index, bits) {
      fail("\{Repr(lengths)}, root \{root_bits}: bits \{bits}")
    }
  }
  let mut offset = 1 << root_bits
  for r, d in deepest {
    if d > 0 {
      assert_eq(table[3 + r], ((offset << 4) | d).to_uint16())
      offset += 1 << (d - root_bits)
    }
  }
  assert_eq(size, offset)
  // Nothing past the table is written.
  assert_eq(table[3 + size], 1)
  assert_eq(table[2], 1)
  size
}

///|
/// Kraft's sum of `lengths` (each 0 to 15) in units of `2^-15`.
fn space(lengths : FixedArray[Int32]) -> Int32 {
  lengths.fold(init=0, (sum, l) => if l > 0 { sum + (32768 >> l) } else { sum })
}

///|
/// Random lengths of a prefix code over `alphabet` symbols: a tree grown by
/// splitting random leaves, often the deepest, no deeper than 15, its
/// leaves given to random symbols; with `drop`, some leaves are left out,
/// for an incomplete code.
fn random_code(rng : Rng, alphabet : Int32, drop~ : Bool) -> FixedArray[Int32] {
  let leaves = rng.next(alphabet - 1) + 2
  let depths = [0]
  let mut deepest = 0
  for tries = 0
      depths.length() < leaves && tries < 4 * leaves
      tries = tries + 1 {
    let i = if rng.next(4) == 0 { deepest } else { rng.next(depths.length()) }
    if depths[i] < 15 {
      let d = depths[i] + 1
      depths[i] = d
      depths.push(d)
      if d > depths[deepest] {
        deepest = i
      }
    }
  }
  let lengths = FixedArray::make(alphabet, 0)
  let slots = Array::makei(alphabet, s => s)
  for i in 0..<depths.length() {
    let j = i + rng.next(alphabet - i)
    let tmp = slots[i]
    slots[i] = slots[j]
    slots[j] = tmp
    if !drop || rng.next(5) != 0 {
      lengths[slots[i]] = depths[i]
    }
  }
  lengths
}

///|
test "Builder::build: RFC 1951's example" {
  // Symbols A to H with lengths 3, 3, 3, 3, 3, 2, 4, 4: codes 010, 011,
  // 100, 101, 110, 00, 1110, 1111.
  let lengths : FixedArray[Int32] = [3, 3, 3, 3, 3, 2, 4, 4]
  for root in 1..<=5 {
    ignore(check(root, lengths))
  }
  let (table, size) = built(3, lengths)
  inspect(size, content="10")
  // 1110 comes first in the stream as 0, 1, 1, 1: the bit sequence 0b0111.
  inspect(lookup(table, 3, 0b0111), content="100")
  inspect(lookup(table, 3, 0b00), content="82")
}

///|
test "Builder::build: every code of up to 4 symbols up to 9 bits, complete or not" {
  let mut complete = 0
  let mut incomplete = 0
  for n in 1..<=4 {
    let mut count = 1
    for _ in 0..<n {
      count *= 10
    }
    for i in 0..<count {
      let lengths = FixedArray::makei(n, k => {
        let mut digit = i
        for _ in 0..<k {
          digit /= 10
        }
        digit % 10
      })
      let space = space(lengths)
      guard space <= 32768 else { continue }
      for root in [1, 4, 8] {
        ignore(check(root, lengths))
      }
      if space == 32768 {
        complete += 1
      } else {
        incomplete += 1
      }
    }
  }
  // The complete codes of 2 to 4 symbols, some unused; the empty and the
  // incomplete ones.
  inspect(complete, content="38")
  inspect(
    incomplete,
    content=(
      #|10442
    ),
  )
}

///|
test "Builder::build: every shape of complete code of up to 16 codes" {
  // Every count of codes per length (1 to 15) for up to 16 codes, each over
  // the first symbols of a 20-symbol alphabet.
  let counts = Array::make(16, 0)
  let mut shapes = 0
  fn walk(len : Int32, room : Int32, used : Int32) -> Unit raise {
    // `room` is the unfilled share of the code space, in units of 2^-len.
    if room == 0 {
      let lengths = FixedArray::make(20, 0)
      let mut s = 0
      for l in 1..<=15 {
        for _ in 0..<counts[l] {
          lengths[s] = l
          s += 1
        }
      }
      for root in [5, 8, 11] {
        ignore(check(root, lengths))
      }
      shapes += 1
      return
    }
    guard len <= 15 && room <= 16 - used else { return }
    for c = room.min(16 - used); c >= 0; c = c - 1 {
      counts[len] = c
      walk(len + 1, (room - c) * 2, used + c)
    }
    counts[len] = 0
  }
  walk(1, 2, 0)
  inspect(shapes, content="3711")
}

///|
test "Builder::build: random codes, complete or not, over DEFLATE's and Brotli's alphabets" {
  let rng = Rng::{ state: 1951, }
  for i in 0..<240 {
    let alphabet = [19, 30, 256, 288, 704][i % 5]
    let lengths = random_code(rng, alphabet, drop=i % 2 == 1)
    let root = [6, 8, 9, 10, 11, 15][i % 6]
    ignore(check(root, lengths))
  }
}

///|
test "Builder::build: a lone symbol takes its code and leaves the rest invalid" {
  let lengths = FixedArray::make(288, 0)
  lengths[100] = 1
  let (table, size) = built(9, lengths)
  inspect(size, content="512")
  inspect(lookup(table, 9, 0) == ((100 << 4) | 1).to_uint16(), content="true")
  inspect(lookup(table, 9, 1) == INVALID, content="true")
}

///|
test "panic Builder::build: over-subscribed lengths" {
  let lengths : FixedArray[Int32] = [1, 1, 1]
  ignore(built(8, lengths))
}

///|
test "panic Builder::build: no room for the table" {
  let builder = @huffman.Builder(root_bits=8, max_alphabet=2)
  let table = FixedArray::make(255, (0 : UInt16))
  ignore(builder.build(table, 0, [1, 1], 2, invalid=0))
}

///|
test "panic Builder: a root of 16 bits" {
  ignore(@huffman.Builder(root_bits=16, max_alphabet=2))
}

///|
test "panic Builder: an alphabet past what entries hold" {
  ignore(@huffman.Builder(root_bits=8, max_alphabet=4097))
}

///|
test "Builder::memory_usage counts its scratch space" {
  inspect(
    @huffman.Builder(root_bits=10, max_alphabet=286).memory_usage(),
    content="2300",
  )
  inspect(
    @huffman.Builder(root_bits=8, max_alphabet=30).memory_usage(),
    content="508",
  )
}
