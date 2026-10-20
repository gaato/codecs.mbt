// `Fse::build` against RFC 8878 section 4.1.1, written out the way the RFC
// explains it rather than the way the decoder computes it.

///|
/// The decoding table of `probs` (-1 standing for "less than 1") at
/// accuracy `log`: each state's symbol, Number_of_Bits and Baseline. `None`
/// when the symbols do not take every state exactly once.
fn fse_reference(
  probs : Array[Int32],
  log : Int32,
) -> Array[(Int32, Int32, Int32)]? {
  let size = 1 << log
  let symbol = Array::make(size, -1)
  // "Less than 1" symbols each take one state from the end of the table,
  // going down, in symbol order.
  let low = Array::make(size, false)
  let mut last = size - 1
  for s, p in probs {
    if p == -1 {
      guard last >= 0 else { return None }
      symbol[last] = s
      low[last] = true
      last -= 1
    }
  }
  // The others are spread: from state 0, one state per unit of
  // probability, moving by the step and skipping the states taken above.
  // (State 0 is taken only when every state is; stopping there ends the
  // skip, and the next symbol finds it taken.)
  let step = size / 2 + size / 8 + 3
  let mut position = 0
  for s, p in probs {
    for _ in 0..<p {
      guard symbol[position] == -1 else { return None }
      symbol[position] = s
      position = (position + step) % size
      while low[position] && position != 0 {
        position = (position + step) % size
      }
    }
  }
  guard !symbol.contains(-1) else { return None }
  // Each symbol's states, in natural order: with `count` states and `power`
  // the next power of 2, the first `power - count` read one bit more. The
  // Baselines count up from 0 over the states that read fewer bits, then
  // wrap around to the first ones.
  let states : Array[Array[Int32]] = Array::makei(probs.length(), _ => [])
  for i, s in symbol {
    states[s].push(i)
  }
  let table = Array::make(size, (0, 0, 0))
  for s, cells in states {
    let count = cells.length()
    guard count > 0 else { continue }
    let mut power = 1
    let mut power_log = 0
    while power < count {
      power *= 2
      power_log += 1
    }
    let width = log - power_log
    let doubled = power - count
    let mut baseline = 0
    for k in doubled..<count {
      table[cells[k]] = (s, width, baseline)
      baseline += 1 << width
    }
    for k in 0..<doubled {
      table[cells[k]] = (s, width + 1, baseline)
      baseline += 1 << (width + 1)
    }
  }
  Some(table)
}

///|
/// Every state of `table` as (symbol, Number_of_Bits, Baseline).
fn fse_cells(table : Fse) -> Array[(Int32, Int32, Int32)] {
  [
    for i in 0..<(1 << table.log) => {
      (
        table.symbol[i].to_int(),
        table.nbits[i].to_int(),
        table.base[i].to_int(),
      )
    }
  ]
}

///|
/// The properties a decoding table must have whatever its distribution:
/// each symbol takes as many states as its probability (one for "less than
/// 1"), and each symbol's next-state ranges `[Baseline, Baseline +
/// 2^Number_of_Bits)` cover every state exactly once.
fn check_fse_properties(
  probs : Array[Int32],
  cells : Array[(Int32, Int32, Int32)],
) -> Unit raise {
  let size = cells.length()
  for s, p in probs {
    let mine = cells.filter(c => c.0 == s)
    assert_eq(mine.length(), if p == -1 { 1 } else { p.max(0) })
    guard mine.length() > 0 else { continue }
    let covered = Array::make(size, 0)
    for cell in mine {
      for state in cell.2..<(cell.2 + (1 << cell.1)) {
        covered[state] += 1
      }
    }
    assert_true(covered.iter().all(n => n == 1))
  }
}

///|
/// Builds `probs` with `Fse::build` and checks it against the reference.
fn check_fse_build(probs : Array[Int32], log : Int32) -> Unit raise {
  let table = Fse::new(9)
  let built = table.build(
    FixedArray::from_array(probs),
    probs.length(),
    log,
    FixedArray::make(256, 0),
  )
  assert_true(built)
  guard fse_reference(probs, log) is Some(expected) else {
    fail("the reference refuses \{Repr(probs)}")
  }
  let cells = fse_cells(table)
  assert_eq(cells, expected)
  check_fse_properties(probs, cells)
}

///|
test "Fse::build: the predefined distributions match the RFC" {
  check_fse_build(ll_default.iter().to_array(), 6)
  check_fse_build(ml_default.iter().to_array(), 6)
  check_fse_build(of_default.iter().to_array(), 5)
  assert_eq(
    fse_cells(ll_predefined),
    fse_reference(ll_default.iter().to_array(), 6).unwrap(),
  )
  assert_eq(
    fse_cells(ml_predefined),
    fse_reference(ml_default.iter().to_array(), 6).unwrap(),
  )
  assert_eq(
    fse_cells(of_predefined),
    fse_reference(of_default.iter().to_array(), 5).unwrap(),
  )
}

///|
/// A random distribution summing to `1 << log`, of up to 256 symbols, with
/// zeros and "less than 1" among them.
fn random_distribution(rng : Rng, log : Int32) -> Array[Int32] {
  let size = 1 << log
  // Some distributions are many small probabilities, some a few large.
  let cap = [1, 2, 8, size][rng.below(4)]
  let probs = []
  let mut remaining = size
  while remaining > 0 && probs.length() < 255 {
    match rng.below(8) {
      0 => probs.push(0)
      1 => {
        probs.push(-1)
        remaining -= 1
      }
      _ => {
        let p = 1 + rng.below(remaining.min(cap))
        probs.push(p)
        remaining -= p
      }
    }
  }
  if remaining > 0 {
    probs.push(remaining)
  }
  probs
}

///|
test "Fse::build: random distributions match the RFC" {
  let rng = Rng::new(4114)
  for i in 0..<2000 {
    let log = 5 + i % 5
    check_fse_build(random_distribution(rng, log), log)
  }
  // The extremes: one symbol with every state, and all "less than 1".
  for log in 5..<=9 {
    check_fse_build([1 << log], log)
    check_fse_build([0, 0, 1 << log], log)
    check_fse_build(Array::make((1 << log).min(256), -1), log.min(8))
  }
}
