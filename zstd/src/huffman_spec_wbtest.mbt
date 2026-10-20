// `Huffman::build` against RFC 8878 section 4.2.1: weights to code lengths
// to prefix codes, written out the way the RFC explains them rather than
// the way the decoder computes them.

///|
/// The decoding table of the explicit `weights` (the last symbol's weight
/// implied): `Max_Number_of_Bits`, and for each `Max_Number_of_Bits`-bit
/// index the symbol whose code it starts with and that code's length.
/// `None` for weights the decoder refuses.
fn huffman_reference(weights : Array[Int32]) -> (Int32, Array[(Int32, Int32)])? {
  guard weights.iter().all(w => w >= 0 && w <= MAX_HUF_BITS) else {
    return None
  }
  let total = weights.fold(init=0, (sum, w) => {
    if w > 0 {
      sum + (1 << (w - 1))
    } else {
      sum
    }
  })
  guard total > 0 else { return None }
  // The total is rounded up to the next power of 2, 2^Max_Number_of_Bits;
  // the difference must itself be a power of 2, the implied weight's share.
  let mut max_bits = 0
  while 1 << max_bits <= total {
    max_bits += 1
  }
  guard max_bits <= MAX_HUF_BITS else { return None }
  let left = (1 << max_bits) - total
  let mut implied = 1
  while 1 << (implied - 1) < left {
    implied += 1
  }
  guard 1 << (implied - 1) == left else { return None }
  let all = [..weights, implied]
  // The decoder also wants a weight of 1, as the reference decoder does.
  guard all.contains(1) else { return None }
  // Number_of_Bits = Max_Number_of_Bits + 1 - Weight. Codes go to symbols
  // by increasing weight, then increasing symbol, counting up from 0 and
  // dropping the low bits whenever the code gets shorter.
  let order = [ for s, w in all if w > 0 => (w, s) ]
  order.sort()
  let table = Array::make(1 << max_bits, (-1, 0))
  let mut code = 0
  let mut code_len = max_bits + 1 - order[0].0
  for entry in order {
    let (w, s) = entry
    let len = max_bits + 1 - w
    guard code % (1 << (code_len - len)) == 0 else { return None }
    code = code >> (code_len - len)
    code_len = len
    // The code is the first `len` bits of the indices it covers.
    let first = code << (max_bits - len)
    let span = 1 << (max_bits - len)
    for i in first..<(first + span) {
      guard i < table.length() && table[i].0 == -1 else { return None }
      table[i] = (s, len)
    }
    code += 1
  }
  // Kraft's equality: the codes fill the index space exactly.
  guard code == 1 << code_len else { return None }
  Some((max_bits, table))
}

///|
/// Builds the explicit `weights` with `Huffman::build`: `Max_Number_of_Bits`
/// and the table, or `None` when it refuses them.
fn huffman_built(
  huffman : Huffman,
  weights : Array[Int32],
) -> (Int32, Array[(Int32, Int32)])? {
  for i, w in weights {
    huffman.weights[i] = w
  }
  huffman.build(weights.length()) catch {
    _ => return None
  }
  Some((huffman.max_bits, huffman_table(huffman)))
}

///|
fn huffman_table(huffman : Huffman) -> Array[(Int32, Int32)] {
  [
    for i in 0..<(1 << huffman.max_bits) => {
      (huffman.symbol[i].to_int(), huffman.nbits[i].to_int())
    }
  ]
}

///|
/// Kraft's equality on the code lengths in `table`, each symbol counted
/// once: the sum of `2^-length` is exactly 1.
fn check_kraft(max_bits : Int32, table : Array[(Int32, Int32)]) -> Unit raise {
  let lengths : Map[Int32, Int32] = Map([])
  for entry in table {
    lengths[entry.0] = entry.1
  }
  let sum = lengths
    .values()
    .fold(init=0, (sum, len) => sum + (1 << (max_bits - len)))
  assert_eq(sum, 1 << max_bits)
}

///|
/// Random explicit weights of a complete prefix code: a tree grown by
/// splitting random leaves no deeper than 11, its leaves given to random
/// symbols. The implied (last) symbol's weight is left out.
fn random_code(rng : Rng) -> Array[Int32] {
  let leaves = rng.below(255) + 2
  let depths = [0]
  for tries = 0
      depths.length() < leaves && tries < 4 * leaves
      tries = tries + 1 {
    let i = rng.below(depths.length())
    if depths[i] < MAX_HUF_BITS {
      let d = depths[i] + 1
      depths[i] = d
      depths.push(d)
    }
  }
  let max_bits = depths.fold(init=0, (m, d) => m.max(d))
  // Spread the leaves over up to 256 symbols, with unused ones between.
  let symbols = (depths.length() + rng.below(257 - depths.length())).min(256)
  let weights = Array::make(symbols, 0)
  let slots = [ for s in 0..<symbols => s ]
  for i in 0..<depths.length() {
    let j = i + rng.below(symbols - i)
    let tmp = slots[i]
    slots[i] = slots[j]
    slots[j] = tmp
    weights[slots[i]] = max_bits + 1 - depths[i]
  }
  // The last used symbol's weight is implied.
  let mut last = symbols - 1
  while weights[last] == 0 {
    last -= 1
  }
  weights[:last].to_owned()
}

///|
test "Huffman::build: the RFC's example" {
  // Literals 0 to 5 with weights 4, 3, 2, 0, 1 and the implied 1:
  // codes 1, 01, 001, (none), 0000, 0001.
  let huffman = Huffman::new()
  let built = huffman_built(huffman, [4, 3, 2, 0, 1])
  assert_eq(built, huffman_reference([4, 3, 2, 0, 1]))
  debug_inspect(
    built,
    content=(
      #|Some(
      #|  (
      #|    4,
      #|    [
      #|      (4, 4),
      #|      (5, 4),
      #|      (2, 3),
      #|      (2, 3),
      #|      (1, 2),
      #|      (1, 2),
      #|      (1, 2),
      #|      (1, 2),
      #|      (0, 1),
      #|      (0, 1),
      #|      (0, 1),
      #|      (0, 1),
      #|      (0, 1),
      #|      (0, 1),
      #|      (0, 1),
      #|      (0, 1),
      #|    ],
      #|  ),
      #|)
    ),
  )
}

///|
test "Huffman::build: random complete codes match the RFC" {
  let rng = Rng::new(1717)
  let huffman = Huffman::new()
  for _ in 0..<3000 {
    let weights = random_code(rng)
    let built = huffman_built(huffman, weights)
    guard built is Some((max_bits, table)) else {
      fail("refused \{Repr(weights)}")
    }
    assert_eq(built, huffman_reference(weights))
    check_kraft(max_bits, table)
  }
}

///|
test "Huffman::build: random weights are refused exactly when the RFC refuses them" {
  let rng = Rng::new(99)
  let huffman = Huffman::new()
  let mut accepted = 0
  for i in 0..<20000 {
    let count = 1 + rng.below(if i % 2 == 0 { 8 } else { 255 })
    let top = [3, 5, 12][rng.below(3)]
    let weights = [ for _ in 0..<count => rng.below(top + 1) ]
    let built = huffman_built(huffman, weights)
    assert_eq(built, huffman_reference(weights))
    if built is Some((max_bits, table)) {
      check_kraft(max_bits, table)
      accepted += 1
    }
  }
  // Both outcomes occur.
  assert_true(accepted > 100 && accepted < 19900)
}
