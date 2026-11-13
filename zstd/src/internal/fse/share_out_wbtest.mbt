// `settle` is what makes `normalize` correct by construction, clamping
// shares that would not add up; these check that it never needs to, since
// `share_out` already makes them add up.

///|
test "share_out: settle keeps every share it is given" {
  let mut state = 2026U
  // A 32-bit LCG, for reproducible tests: a number in `0..<bound`.
  let below = (bound : Int32) => {
    state = state * 1664525 + 1013904223
    (state >> 8).reinterpret_as_int() % bound
  }
  for round in 0..<3000 {
    let max_n = [36, 53, 32, 12][round % 4]
    let n = 1 + below(max_n)
    let counts = FixedArray::make(n, 0)
    for s in 0..<n {
      counts[s] = if below(3) == 0 { 0 } else { below(1 << below(14)) }
    }
    counts[n - 1] += 1
    let total = counts.fold(init=0, (a, b) => a + b)
    let log = accuracy_log(total, n, [9, 9, 8, 6][round % 4])
    let size = 1 << log
    let norm = FixedArray::make(n, 0)
    share_out(counts, n, total, size, norm)
    let shares = norm.copy()
    settle(counts, n, total, size, false, norm)
    assert_eq(norm, shares)
  }
}

///|
test "settle: whatever shares it is given, the states add up and fit" {
  let mut state = 7U
  let below = (bound : Int32) => {
    state = state * 1664525 + 1013904223
    (state >> 8).reinterpret_as_int() % bound
  }
  for round in 0..<3000 {
    let log = 5 + below(5)
    let size = 1 << log
    let n = 1 + below(size.min(60))
    let counts = FixedArray::makei(n, _ => {
      if below(3) == 0 {
        0
      } else {
        1 + below(100)
      }
    })
    counts[n - 1] += 1
    let total = counts.fold(init=0, (a, b) => a + b)
    // Shares that need not add up or fit: too small, too large, anything.
    let norm = FixedArray::makei(n, _ => below(size + 3) - 2)
    let low = round % 2 == 0
    settle(counts, n, total, size, low, norm)
    let mut states = 0
    for s in 0..<n {
      if counts[s] == 0 {
        assert_eq(norm[s], 0)
      } else {
        assert_true(norm[s] >= 1 || (low && norm[s] == -1))
      }
      states += if norm[s] == -1 { 1 } else { norm[s] }
    }
    assert_eq(states, size)
  }
}
