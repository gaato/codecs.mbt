// The encoder's FSE pieces on their own; their round trips through the
// decoder are in the zstd package's fse_encode_wbtest.mbt.

///|
/// The states `norm[0:n]` take, -1 counting as 1.
fn states_of(norm : FixedArray[Int32], n : Int32) -> Int32 {
  for i = 0, sum = 0; i < n; {
    continue i + 1, sum + (if norm[i] == -1 { 1 } else { norm[i] })
  } nobreak {
    sum
  }
}

///|
/// Normalizes `counts` and checks what `moon prove` proves of the result:
/// it fills the table, and fits the counts.
fn check_normalize(
  counts : FixedArray[Int32],
  log : Int32,
  low : Bool,
) -> FixedArray[Int32] raise {
  let n = counts.length()
  let total = counts.fold(init=0, (a, b) => a + b)
  let norm = FixedArray::make(n, 77)
  @fse.normalize(counts, n, total, log, low, norm)
  assert_eq(states_of(norm, n), 1 << log)
  for s in 0..<n {
    if counts[s] == 0 {
      assert_eq(norm[s], 0)
    } else {
      assert_true(norm[s] >= 1 || (low && norm[s] == -1))
    }
  }
  norm
}

///|
test "normalize: every histogram of three symbols of up to 12" {
  for log in 5..<=9 {
    for a in 0..<=12 {
      for b in 0..<=12 {
        for c in 1..<=12 {
          check_normalize([a, b, c], log, log % 2 == 0) |> ignore
        }
      }
    }
  }
}

///|
test "normalize: shares follow the counts" {
  debug_inspect(
    check_normalize([1, 1], 5, false),
    content="<FixedArray: [16, 16]>",
  )
  debug_inspect(
    check_normalize([3, 1], 5, false),
    content="<FixedArray: [24, 8]>",
  )
  // One symbol takes every state.
  debug_inspect(
    check_normalize([0, 0, 9], 6, true),
    content="<FixedArray: [0, 0, 64]>",
  )
  // Rare symbols: one state each, -1 when asked for.
  debug_inspect(
    check_normalize([1000, 1, 0, 1], 5, true),
    content="<FixedArray: [30, -1, 0, -1]>",
  )
  debug_inspect(
    check_normalize([1000, 1, 0, 1], 5, false),
    content="<FixedArray: [30, 1, 0, 1]>",
  )
  // As many symbols as states, most of them rare: rounding up gives out
  // too many, and they are taken back.
  let counts = FixedArray::make(32, 1)
  counts[0] = 2
  counts[31] = 40
  let norm = check_normalize(counts, 5, false)
  assert_true(norm.iter().all(p => p == 1))
}

///|
test "normalize: random histograms at the largest alphabets" {
  let rng = Rng::{ state: 1, }
  for round in 0..<2000 {
    let (n, log) = match round % 4 {
      0 => (36, 9)
      1 => (53, 9)
      2 => (32, 8)
      _ => (12, 6)
    }
    let n = 1 + rng.below(n)
    let counts = FixedArray::make(n, 0)
    for s in 0..<n {
      counts[s] = if rng.below(3) == 0 {
        0
      } else {
        rng.below(1 << rng.below(12))
      }
    }
    counts[n - 1] += 1
    let total = counts.fold(init=0, (a, b) => a + b)
    let log = @fse.accuracy_log(total, n, log)
    check_normalize(counts, log, round % 2 == 0) |> ignore
  }
}

///|
test "accuracy_log: within its bounds, and room for every symbol" {
  inspect(@fse.accuracy_log(100000, 36, 9), content="9")
  inspect(@fse.accuracy_log(10, 2, 9), content="5")
  inspect(@fse.accuracy_log(10, 53, 9), content="6")
  inspect(@fse.accuracy_log(1, 1, 6), content="5")
  inspect(@fse.accuracy_log(300, 12, 6), content="6")
  for total in 1..<5000 {
    for symbols in [1, 2, 12, 32, 36, 53] {
      for max_log in 6..<=9 {
        let log = @fse.accuracy_log(total, symbols, max_log)
        assert_true(log >= 5 && log <= max_log)
        assert_true(1 << log >= symbols)
      }
    }
  }
}

///|
test "spread: each symbol on as many states as it has, and -1 at the top" {
  let symbols = FixedArray::make(32, b'\xff')
  assert_true(@fse.spread([-1, 20, 0, 10, -1], 5, 5, symbols))
  inspect(symbols[31], content="b'\\x00'")
  inspect(symbols[30], content="b'\\x04'")
  let counts = FixedArray::make(5, 0)
  for b in symbols {
    counts[b.to_int()] += 1
  }
  debug_inspect(counts, content="<FixedArray: [1, 20, 0, 10, 1]>")
  // States that do not add up to the table leave the spread elsewhere.
  assert_false(@fse.spread([20, 10], 2, 5, symbols))
}

///|
/// A seeded pseudo-random generator (a 32-bit LCG), for reproducible tests.
struct Rng {
  mut state : UInt32
}

///|
/// A number in `0..<bound`.
fn Rng::below(self : Rng, bound : Int32) -> Int32 {
  self.state = self.state * 1664525 + 1013904223
  (self.state >> 8).reinterpret_as_int() % bound
}

///|
test "CTable: memory for the largest table" {
  let table = @fse.CTable(max_log=9, max_symbols=53)
  // 512 states of 4 bytes, three arrays of 53, and 512 bytes of scratch.
  inspect(table.memory_usage(), content="3196")
}
