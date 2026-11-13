// From counts to a normalized distribution (RFC 8878 section 4.1.1): each
// symbol's share of 2^Accuracy_Log states, close to its share of the
// counts, with -1 for "less than one state". The shares must add up to the
// table exactly, or the decoder refuses the description; `moon prove`
// checks that they do (PROOFS.md).

///|
/// The smallest accuracy log a table description can state: its four-bit
/// field counts from 5.
pub const MIN_LOG : Int32 = 5

///|
/// An accuracy log for a table of `symbols` symbols (from 0 to the last one
/// seen, at most `1 << max_log` of them) whose counts add up to `total`, at
/// most `max_log` (RFC 8878 caps it at 9 for literal and match lengths, 8
/// for offsets and 6 for Huffman weights).
///
/// The reference encoder's choice (`FSE_optimalTableLog`): as precise as
/// `max_log` allows, but no more than the counts can use (two bits fewer
/// than `total` has) and no less than the symbols need. Unlike it, the table
/// also has a state for every symbol up to the last, used or not, which
/// `normalize` needs to be sure the shares come out exact; this costs
/// nothing but for tiny blocks of rare symbols, which rarely pay for a table
/// of their own anyway.
pub fn accuracy_log(total : Int32, symbols : Int32, max_log : Int32) -> Int32 {
  let mut log = max_log
  let from_total = high_bit((total - 1).max(1)) - 2
  if from_total < log {
    log = from_total
  }
  let least = (high_bit(total.max(1)) + 1).min(high_bit(symbols.max(1)) + 2)
  if least > log {
    log = least
  }
  log = log.max(MIN_LOG).min(max_log)
  while 1 << log < symbols && log < max_log {
    log += 1
  }
  log
}

///|
/// The position of the highest set bit of `x` (at least 1).
fn high_bit(x : Int32) -> Int32 {
  31 - x.clz()
}

///|
/// Normalizes `counts[0:n]`, symbols seen `total` times in all (at most
/// 2^17, a block's worth), to probabilities `norm[0:n]` over `1 << log`
/// states (`log` from 5 to 9, and `n` at most `1 << log`). `counts[n - 1]`,
/// the last symbol, must have been seen.
///
/// The probabilities add up to exactly `1 << log`, with -1 counting as 1;
/// a symbol never seen gets 0, every other at least 1, or -1 when
/// `low_probability` and its share is at most one state. (The reference
/// encoder uses -1 for blocks of 2,048 sequences or more, and never for
/// Huffman weights.)
///
/// As in the reference encoder (`FSE_normalizeCount`), each share is
/// rounded down, or up when it is below 8 and its fraction beats a
/// threshold that rises with the share, and the states left over go to the
/// most frequent symbol. When rounding up gave out too many, the excess is
/// taken back one state at a time from the symbol that loses the least for
/// it, where the reference encoder switches to another method. `settle`
/// then writes the probabilities out, and `moon prove` checks that what it
/// writes adds up and fits the counts, whatever the shares it was given
/// (PROOFS.md).
pub fn normalize(
  counts : FixedArray[Int32],
  n : Int32,
  total : Int32,
  log : Int32,
  low_probability : Bool,
  norm : FixedArray[Int32],
) -> Unit {
  let size = 1 << log
  share_out(counts, n, total, size, norm)
  settle(counts, n, total, size, low_probability, norm)
}

///|
/// The fraction, in 8,192ths, that a share `q` below 8 must beat to round
/// up: the reference encoder's thresholds (`FSE_normalizeCount`, in
/// 2^20ths), which make a small share round up less readily as it grows.
let round_up_threshold : FixedArray[Int32] = [
  0, 3697, 3940, 4069, 4297, 5469, 5859, 6484,
]

///|
/// Sets `norm[0:n]` to each symbol's share of `size` states, rounded and at
/// least 1 for every symbol seen, and then makes them add up to `size`.
fn share_out(
  counts : FixedArray[Int32],
  n : Int32,
  total : Int32,
  size : Int32,
  norm : FixedArray[Int32],
) -> Unit {
  let mut given = 0
  for s in 0..<n {
    let c = counts[s]
    let p = if c == 0 {
      0
    } else if c * size <= total {
      1
    } else {
      // At least 1, as `c * size > total`. The products stay below 2^31:
      // `c * size` below 2^26, `rest * 8192` and the threshold's below 2^30.
      let q = c * size / total
      let rest = c * size - q * total
      if q < 8 && rest * 8192 > round_up_threshold[q] * total {
        q + 1
      } else {
        q
      }
    }
    norm[s] = p
    given += p
  }
  if given <= size {
    let mut k = n - 1
    for s in 0..<n {
      if norm[s] > norm[k] {
        k = s
      }
    }
    norm[k] += size - given
  } else {
    for _ in 0..<(given - size) {
      let k = cheapest(counts, n, norm)
      // Never -1 while `n <= size`: the symbols seen have one state each
      // at least, so more than `size` states means one has two.
      if k >= 0 {
        norm[k] -= 1
      }
    }
  }
}

///|
/// Among the symbols with 2 or more states, the one whose code grows least
/// by losing one: the fewest occurrences per state, the last of them. -1
/// when none has 2.
fn cheapest(
  counts : FixedArray[Int32],
  n : Int32,
  norm : FixedArray[Int32],
) -> Int32 {
  let mut best = -1
  for s in 0..<n {
    if norm[s] >= 2 &&
      (best < 0 || counts[s] * norm[best] <= counts[best] * norm[s]) {
      best = s
    }
  }
  best
}

///|
/// Writes the probabilities: those that `norm[0:n]` holds (from
/// `share_out`), kept between 1 and what leaves a state for each symbol
/// seen after, for a symbol seen; 0 for the others; and for the last
/// symbol, the states left. A probability of 1 whose share of the counts
/// was at most one state becomes -1 when `low_probability`.
///
/// So the probabilities add up to `size` and fit the counts by
/// construction, whatever `norm` held; with the shares of `share_out`,
/// which already add up and fit, nothing is kept in or left over.
fn settle(
  counts : FixedArray[Int32],
  n : Int32,
  total : Int32,
  size : Int32,
  low_probability : Bool,
  norm : FixedArray[Int32],
) -> Unit where {
  proof_require: settle_pre(counts, n, total, size, norm),
  proof_ensure: settle_post(counts, n, size, norm),
} {
  let all_seen = count_seen(counts, n)
  for s = 0, sum = 0, low = 0, ahead = all_seen; s < n; {
    proof_assert seen(counts, s, n) ==
      seen(counts, s + 1, n) + (if counts[s] > 0 { 1 } else { 0 })
    let left = size - sum - 2 * low
    let c = counts[s]
    let wanted = norm[s]
    let p = if c == 0 {
      0
    } else if s == n - 1 {
      left
    } else if wanted < 1 {
      1
    } else if wanted > left - (ahead - 1) {
      left - (ahead - 1)
    } else {
      wanted
    }
    let p = if low_probability && p == 1 && c * size <= total { -1 } else { p }
    put(counts, s, p, sum, low, norm)
    let next_low = if p == -1 { low + 1 } else { low }
    let next_ahead = if c > 0 { ahead - 1 } else { ahead }
    continue s + 1, sum + p, next_low, next_ahead
  } where {
    proof_invariant: 0 <= s && s <= n,
    proof_invariant: ahead == seen(counts, s, n),
    proof_invariant: ahead <= size - sum - 2 * low,
    proof_invariant: s == n || ahead >= 1,
    proof_invariant: s < n || sum + 2 * low == size,
    proof_invariant: sum == total_of(norm, 0, s),
    proof_invariant: low == count_of(norm, -1, 0, s),
    proof_invariant: all_fit(counts, norm, s),
  }
}

///|
/// Sets `norm[s]` to `p`, which fits `counts[s]`, after `norm[0:s]`, which
/// add up to `sum` and hold `low` -1s, and fit their counts.
fn put(
  counts : FixedArray[Int32],
  s : Int32,
  p : Int32,
  sum : Int32,
  low : Int32,
  norm : FixedArray[Int32],
) -> Unit where {
  proof_require: 0 <= s && s < counts.length() && s < norm.length(),
  proof_require: sum == total_of(norm, 0, s) && low == count_of(norm, -1, 0, s),
  proof_require: all_fit(counts, norm, s) && fits(counts[s], p),
  proof_ensure: total_of(norm, 0, s + 1) == sum + p,
  proof_ensure: count_of(norm, -1, 0, s + 1) ==
  low + (if p == -1 { 1 } else { 0 }),
  proof_ensure: all_fit(counts, norm, s + 1),
} {
  norm[s] = p
  // The elements before `s` are as they were.
  proof_assert all_fit(counts, norm, s)
  proof_assert fits(counts[s], norm[s])
  proof_assert total_of(norm, 0, s) == sum
  proof_assert count_of(norm, -1, 0, s) == low
}

///|
/// The symbols of `counts[0:n]` seen.
fn count_seen(
  counts : FixedArray[Int32],
  n : Int32,
) -> Int32 where {
  proof_require: 0 <= n && n <= counts.length(),
  proof_ensure: result => result == seen(counts, 0, n),
} {
  for s = 0, found = 0; s < n; {
    continue s + 1, if counts[s] != 0 { found + 1 } else { found }
  } nobreak {
    found
  } where {
    proof_invariant: 0 <= s && s <= n,
    proof_invariant: found == seen(counts, 0, s),
    proof_yield: result => result == seen(counts, 0, n),
  }
}
