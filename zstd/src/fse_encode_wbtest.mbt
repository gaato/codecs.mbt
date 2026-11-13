// The encoder's FSE pieces (internal/fse) against the decoder's: table
// descriptions read back by `Fse::read` into the same table and the same
// probabilities, and streams decoded by `Fse` tables to the symbols
// encoded, using every bit.

///|
/// Writes the description of `probs` and reads it back: the decoder takes
/// all of its bytes and no more, reads `probs`, and builds the table that
/// `Fse::build` builds from them.
fn check_description(probs : Array[Int32], log : Int32) -> Unit raise {
  let norm = FixedArray::from_array(probs)
  let out = @bits.BitPacker()
  @fse.write_description(out, norm, probs.length(), log)
  // A byte after the description, which the decoder must not take.
  out.write(8, 0xa5)
  let data = packed(out)
  let table = Fse::new(9)
  let scratch = FseScratch::new()
  let used = table.read(data, 0, data.length(), 9, 255, scratch)
  assert_eq(used, data.length() - 1)
  assert_eq(table.log, log)
  for s, p in probs {
    assert_eq(scratch.probs[s], p)
  }
  let expected = Fse::new(9)
  assert_true(
    expected.build(norm, probs.length(), log, FixedArray::make(256, 0)),
  )
  assert_eq(fse_cells(table), fse_cells(expected))
}

///|
/// Encodes `symbols` (at least one) with the encoder's table of `probs`,
/// one state, and decodes them with the decoder's: the same symbols, and
/// every bit of the stream read.
fn check_stream(
  probs : Array[Int32],
  log : Int32,
  symbols : Array[Int32],
) -> Unit raise {
  let norm = FixedArray::from_array(probs)
  let table = @fse.CTable(max_log=9, max_symbols=256)
  table.build(norm, probs.length(), log)
  assert_eq(table.log(), log)
  let out = @bits.BitPacker()
  let n = symbols.length()
  let mut state = table.start(symbols[n - 1])
  for i = n - 2; i >= 0; i = i - 1 {
    state = table.encode(out, state, symbols[i])
  }
  table.finish(out, state)
  out.write_end_mark()
  let data = packed(out)
  let decoder = Fse::new(9)
  assert_true(
    decoder.build(norm, probs.length(), log, FixedArray::make(256, 0)),
  )
  let bits = BackwardBits::new(data, 0, data.length())
  let mut state = bits.read(log)
  for i in 0..<n {
    assert_eq(decoder.symbol_of(state), symbols[i])
    if i < n - 1 {
      state = decoder.next(state, bits)
    }
  }
  assert_eq(bits.pos, 0)
}

///|
/// `count` symbols drawn from `probs`, each symbol as often as it has
/// states, roughly.
fn draw(rng : Rng, probs : Array[Int32], count : Int32) -> Array[Int32] {
  let pool = []
  for s, p in probs {
    for _ in 0..<(if p == -1 { 1 } else { p }) {
      pool.push(s)
    }
  }
  [
    for _ in 0..<count => pool[rng.below(pool.length())]
  ]
}

///|
/// Every distribution over `log = 5` of up to three symbols, the last one
/// nonzero, with -1 and zeros: the description reads back, and streams of
/// each symbol alone and of all of them in turn decode.
test "FSE encoding: every small distribution round-trips" {
  let size = 32
  let values = [-1, 0, ..(1).until(size + 1)]
  let mut tried = 0
  for a in values {
    // One symbol.
    if a == size {
      check_description([a], 5)
      check_stream([a], 5, [0, 0, 0])
      tried += 1
    }
    for b in values {
      let share = (p : Int32) => if p == -1 { 1 } else { p }
      if b != 0 && share(a) + share(b) == size {
        let probs = [a, b]
        check_description(probs, 5)
        let used = [ for s, p in probs if p != 0 => s ]
        check_stream(probs, 5, used + used + used.rev())
        tried += 1
      }
      for c in values {
        if c != 0 && share(a) + share(b) + share(c) == size {
          let probs = [a, b, c]
          check_description(probs, 5)
          let used = [ for s, p in probs if p != 0 => s ]
          check_stream(probs, 5, used + used.rev() + used)
          for s in used {
            check_stream(probs, 5, [s, s, s, s])
          }
          tried += 1
        }
      }
    }
  }
  inspect(
    tried,
    content=(
      #|660
    ),
  )
}

///|
test "FSE encoding: random distributions round-trip at every accuracy log" {
  let rng = Rng::new(8878)
  for round in 0..<400 {
    let log = 5 + round % 5
    let probs = random_distribution(rng, log)
    // A description ends with its last nonzero probability.
    while probs[probs.length() - 1] == 0 {
      probs.pop() |> ignore
    }
    check_description(probs, log)
    check_stream(probs, log, draw(rng, probs, 1 + rng.below(300)))
  }
}

///|
test "FSE encoding: zero runs of every length up to 255 symbols" {
  for run in 0..<253 {
    // A probability, `run` zeros, and the rest.
    let probs = [3, ..Array::make(run, 0), 29]
    check_description(probs, 5)
    check_stream(probs, 5, [0, run + 1, 0, run + 1])
  }
  // Runs right after the first symbol, and several in one description.
  check_description([0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, -1, 0, 0, 30], 5)
  check_description([0, 512], 9)
}

///|
test "FSE encoding: the predefined distributions and the largest tables" {
  check_description(ll_default.iter().to_array(), 6)
  check_description(ml_default.iter().to_array(), 6)
  check_description(of_default.iter().to_array(), 5)
  let rng = Rng::new(1)
  check_stream(
    ll_default.iter().to_array(),
    6,
    draw(rng, ll_default.iter().to_array(), 500),
  )
  // Many -1 probabilities in a table of 512 states: 53 match length codes.
  let probs = Array::make(53, -1)
  probs[52] = 512 - 52
  check_description(probs, 9)
  check_stream(probs, 9, draw(rng, probs, 1000))
  // As many symbols as states.
  let flat = Array::make(64, 1)
  check_description(flat, 6)
  check_stream(flat, 6, draw(rng, flat, 1000))
}

///|
/// Normalizes the counts of random symbols and checks the distribution
/// round-trips; returns it.
fn check_normalized(
  counts : FixedArray[Int32],
  n : Int32,
  max_log : Int32,
  low : Bool,
  rng : Rng,
) -> Array[Int32] raise {
  let total = counts.iter().take(n).fold(init=0, (a, b) => a + b)
  let log = @fse.accuracy_log(total, n, max_log)
  assert_true(log >= 5 && log <= max_log && 1 << log >= n)
  let norm = FixedArray::make(n, 99)
  @fse.normalize(counts, n, total, log, low, norm)
  let probs = norm.iter().to_array()
  check_description(probs, log)
  check_stream(probs, log, draw(rng, probs, 1 + rng.below(200)))
  probs
}

///|
test "FSE encoding: normalized counts round-trip" {
  let rng = Rng::new(42)
  for round in 0..<600 {
    let max_log = [9, 8, 6][round % 3]
    let n = 1 + rng.below([53, 32, 12][round % 3])
    let counts = FixedArray::make(n, 0)
    let skew = 1 + rng.below(4)
    for s in 0..<n {
      counts[s] = match rng.below(skew + 1) {
        0 => 0
        1 => 1 + rng.below(3)
        _ => rng.below(1 << (2 * skew + rng.below(6)))
      }
    }
    counts[n - 1] += 1
    check_normalized(counts, n, max_log, round % 2 == 0, rng) |> ignore
  }
}
