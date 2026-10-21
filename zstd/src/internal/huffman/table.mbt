// From weights to a decoding table (RFC 8878 section 4.2.1): each symbol of
// weight `w > 0` takes 2^(w - 1) consecutive entries of the table, by
// increasing weight and then symbol, each entry giving the symbol and its
// code length `Max_Number_of_Bits + 1 - w`.

///|
/// The longest Huffman code.
const MAX_BITS : Int32 = 11

///|
/// The weights refused: one above 11.
pub const WEIGHT_TOO_LARGE : Int32 = -1

///|
/// No weight but the implied one: a tree of one symbol.
pub const ONE_SYMBOL : Int32 = -2

///|
/// A tree deeper than 11 bits.
pub const TOO_DEEP : Int32 = -3

///|
/// Weights that leave a gap no implied weight fills.
pub const INCOMPLETE : Int32 = -4

///|
/// No weight of 1, which the reference decoder requires.
pub const NO_WEIGHT_ONE : Int32 = -5

///|
/// Weights that overfill the table.
pub const OVERFULL : Int32 = -6

///|
/// Builds the table of the weights `weights[0:count]` (0 to 255 of them,
/// each at least 0) into `symbol` and `nbits` (2,048 entries each), with
/// `wcount` (12 entries) and `start` (13) as scratch space, and returns
/// Max_Number_of_Bits, or one of the refusals above. Unless it refuses the
/// weights before it knows the implied last weight, it leaves that weight
/// in `start[0]`, for the caller to store after the others: the weights
/// themselves it only reads.
pub fn build_table(
  weights : FixedArray[Int32],
  count : Int32,
  symbol : FixedArray[Byte],
  nbits : FixedArray[Byte],
  wcount : FixedArray[Int32],
  start : FixedArray[Int32],
) -> Int32 where {
  proof_require: build_pre(weights, count, symbol, nbits, wcount, start),
  proof_ensure: result => {
    build_post(weights, count, symbol, nbits, wcount, start, result)
  },
} {
  let big = count_weights(weights, count, wcount)
  if big {
    WEIGHT_TOO_LARGE
  } else {
    let total = weight_total(wcount)
    sum_of_counts(wcount, weights, count)
    proof_assert total == weight_sum(weights, count)
    proof_assert all_small(weights, count)
    if total == 0 {
      ONE_SYMBOL
    } else {
      proof_assert total > 0
      let max_bits = bit_length(total)
      if max_bits > MAX_BITS {
        proof_assert some_post(
          weights,
          count,
          symbol,
          nbits,
          wcount,
          start,
          TOO_DEEP,
        )
        TOO_DEEP
      } else {
        let left = @proof_bits.shl(1, max_bits) - total
        proof_assert left == left_of(weights, count)
        lighter_than(wcount, max_bits)
        left_bound(total, max_bits)
        let last = implied_weight(left)
        if last == 0 {
          INCOMPLETE
        } else {
          implied_fits(left, max_bits)
          start[0] = last
          wcount[last] = wcount[last] + 1
          proof_assert counted_all(wcount, weights, count, last)
          proof_assert counts_within(wcount, 256)
          proof_assert none_heavier(wcount, max_bits)
          proof_assert total_upto(wcount, max_bits) ==
            @proof_bits.pow2(max_bits)
          proof_assert wcount[1] == ones(weights, count, last)
          if wcount[1] == 0 {
            proof_assert complete_post(
              weights,
              count,
              last,
              symbol,
              nbits,
              wcount,
              NO_WEIGHT_ONE,
            )
            NO_WEIGHT_ONE
          } else {
            let result = fill(
              weights, count, last, symbol, nbits, wcount, start, max_bits,
            )
            proof_assert complete_post(
              weights, count, last, symbol, nbits, wcount, result,
            )
            result
          }
        }
      }
    }
  }
}

///|
/// Counts the weights of `weights[0:count]` up to 11 into `wcount`, and
/// returns whether one is above 11.
fn count_weights(
  weights : FixedArray[Int32],
  count : Int32,
  wcount : FixedArray[Int32],
) -> Bool where {
  proof_require: count_weights_pre(weights, count, wcount),
  proof_ensure: result => count_weights_post(weights, count, wcount, result),
} {
  for w = 0; w < 12; {
    wcount[w] = 0
    continue w + 1
  } where {
    proof_invariant: 0 <= w && w <= 12,
    proof_invariant: wcount.length() == 12,
    proof_invariant: zero_below(wcount, w),
  }
  for i = 0, big = false; i < count; {
    let w = weights[i]
    if w > MAX_BITS {
      continue i + 1, true
    } else {
      wcount[w] = wcount[w] + 1
      continue i + 1, big
    }
  } nobreak {
    big
  } where {
    proof_invariant: 0 <= i && i <= count,
    proof_invariant: wcount.length() == 12,
    proof_invariant: counted_weights(wcount, weights, i),
    proof_invariant: counts_within(wcount, i),
    proof_invariant: big_upto(weights, i, big),
  }
}

///|
/// The sum of `2^(w - 1)` over the weights `w > 0` that `wcount` counts.
fn weight_total(
  wcount : FixedArray[Int32],
) -> Int32 where {
  proof_require: wcount.length() == 12 && counts_within(wcount, 255),
  proof_ensure: result => result == total_upto(wcount, 11),
} {
  for w = 1, sum = 0; w < 12; {
    total_step(wcount, w - 1)
    share_is(wcount[w], w)
    continue w + 1, sum + @proof_bits.shl(wcount[w], w - 1)
  } nobreak {
    sum
  } where {
    proof_invariant: 1 <= w && w <= 12,
    proof_invariant: sum == total_upto(wcount, w - 1),
  }
}

///|
/// The number of bits of `total` (1 to 2^20): the smallest `b` with
/// `total < 2^b`, or 12 when that is more than 11.
fn bit_length(
  total : Int32,
) -> Int32 where {
  proof_require: 0 < total && total < 1048576,
  proof_ensure: result => result == bits_of(total),
} {
  for b = 1, p = 2; b < 12; {
    if p > total {
      bits_between(total, b)
      break b
    }
    continue b + 1, 2 * p
  } nobreak {
    bits_past_11(total)
    12
  } where {
    proof_invariant: 1 <= b && b <= 12,
    proof_invariant: p == @proof_bits.pow2(b),
    proof_invariant: @proof_bits.pow2(b - 1) <= total,
    proof_yield: result => result == bits_of(total),
  }
}

///|
/// The weight whose share is `left` (1 to 1,024): `k + 1` when `left` is
/// 2^k, 0 when `left` is not a power of 2.
fn implied_weight(
  left : Int32,
) -> Int32 where {
  proof_require: 1 <= left && left <= 1024,
  proof_ensure: result => result == implied_of(left),
} {
  for k = 0, p = 1; k < 11; {
    if p == left {
      implied_at(k)
      break k + 1
    }
    continue k + 1, 2 * p
  } nobreak {
    implied_none(left)
    0
  } where {
    proof_invariant: 0 <= k && k <= 11,
    proof_invariant: p == @proof_bits.pow2(k),
    proof_invariant: not_power_below(left, k),
    proof_yield: result => result == implied_of(left),
  }
}

///|
/// Fills the table for the weights `weights[0:count]`, the implied weight
/// `last` of the symbol after them, and their counts `wcount`: a complete
/// code of `max_bits` bits. The code lengths go by increasing weight, then
/// each symbol's entries. Returns `max_bits`, or OVERFULL, which complete
/// weights never give but the reference decoder checks for.
fn fill(
  weights : FixedArray[Int32],
  count : Int32,
  last : Int32,
  symbol : FixedArray[Byte],
  nbits : FixedArray[Byte],
  wcount : FixedArray[Int32],
  start : FixedArray[Int32],
  max_bits : Int32,
) -> Int32 where {
  proof_require: fill_pre(
    weights, count, last, symbol, nbits, wcount, start, max_bits,
  ),
  proof_ensure: result => {
    result == max_bits &&
    table_ok(weights, count, last, symbol, nbits, wcount, max_bits) &&
    start[0] == last
  },
} {
  totals_grow(wcount)
  let size = @proof_bits.shl(1, max_bits)
  start[1] = 0
  let over = for w = 1; w < max_bits + 1; {
    total_step(wcount, w - 1)
    share_is(wcount[w], w)
    let next = start[w] + @proof_bits.shl(wcount[w], w - 1)
    proof_assert next == total_upto(wcount, w)
    proof_assert total_upto(wcount, w) <= total_upto(wcount, max_bits)
    if next > size {
      break true
    }
    let len = byte_of(max_bits + 1 - w)
    for k = start[w]; k < next; {
      nbits[k] = len
      continue k + 1
    } where {
      proof_invariant: start[w] <= k && k <= next,
      proof_invariant: nbits.length() == 2048,
      proof_invariant: lengths_from(nbits, wcount, max_bits, w, k),
      proof_invariant: blocks_upto(nbits, wcount, max_bits, w),
    }
    start[w + 1] = next
    continue w + 1
  } nobreak {
    false
  } where {
    proof_invariant: 1 <= w && w <= max_bits + 1,
    proof_invariant: start.length() == 13 && nbits.length() == 2048,
    proof_invariant: start[0] == last,
    proof_invariant: starts_upto(start, wcount, w),
    proof_invariant: blocks_upto(nbits, wcount, max_bits, w),
    proof_yield: over => !over,
  }
  if over {
    OVERFULL
  } else {
    all_blocks(weights, count, last, wcount, max_bits)
    for i = 0; i < count + 1; {
      let w = if i == count { last } else { weights[i] }
      if i < count {
        @proof_codes.count_step(weights, i)
        @proof_codes.count_others(weights, i)
      }
      if w > 0 {
        let first = start[w]
        let span = @proof_bits.shl(1, w - 1)
        place_step(weights, count, last, wcount, start, max_bits, i)
        place_apart(weights, count, last, wcount, start, max_bits, i)
        fill_symbol(
          weights, count, last, symbol, nbits, wcount, max_bits, i, first, span,
        )
        proof_assert block_ok(nbits, wcount, max_bits, w)
        proof_assert entries_of(
          weights, count, last, symbol, nbits, wcount, max_bits, i,
        )
        share_rules(w)
        start[w] = first + span
      }
      continue i + 1
    } where {
      proof_invariant: 0 <= i && i <= count + 1,
      proof_invariant: start.length() == 13 && symbol.length() == 2048,
      proof_invariant: start[0] == last,
      proof_invariant: next_entries(start, weights, count, wcount, max_bits, i),
      proof_invariant: entries_upto(
        weights, count, last, symbol, nbits, wcount, max_bits, i,
      ),
    }
    max_bits
  }
}

///|
/// Where symbol `i` of weight `w > 0` goes: `start[w]`, its first entry, in
/// the block of `w`, with room for its 2^(w - 1) entries; the symbols placed
/// before it are elsewhere.
fn place_step(
  weights : FixedArray[Int32],
  count : Int32,
  last : Int32,
  c : FixedArray[Int32],
  start : FixedArray[Int32],
  max_bits : Int32,
  i : Int32,
) -> Unit where {
  proof_require: place_pre(weights, count, last, c, start, max_bits, i),
  proof_ensure: in_block(
    weights,
    count,
    last,
    c,
    max_bits,
    i,
    start[weight_of(weights, count, last, i)],
  ),
} {
  let w = if i == count { last } else { weights[i] }
  if i < count {
    proof_assert @proof_codes.numof(weights, w, 0, i + 1) ==
      @proof_codes.numof(weights, w, 0, i) + 1
    proof_assert @proof_codes.numof(weights, w, 0, count) >=
      @proof_codes.numof(weights, w, 0, i + 1)
  }
  proof_assert @proof_codes.numof(weights, w, 0, i) + 1 <= c[w]
  proof_assert w <= max_bits
  total_step(c, w - 1)
  proof_assert start[w] ==
    total_upto(c, w - 1) + share(@proof_codes.numof(weights, w, 0, i), w)
  proof_assert share(@proof_codes.numof(weights, w, 0, i) + 1, w) <=
    share(c[w], w)
}

///|
/// Gives symbol `i` the `span` entries from `first`, apart from those of
/// the symbols before it.
fn fill_symbol(
  weights : FixedArray[Int32],
  count : Int32,
  last : Int32,
  symbol : FixedArray[Byte],
  nbits : FixedArray[Byte],
  c : FixedArray[Int32],
  max_bits : Int32,
  i : Int32,
  first : Int32,
  span : Int32,
) -> Unit where {
  proof_require: fill_symbol_pre(
    weights, count, last, symbol, nbits, c, max_bits, i, first, span,
  ),
  proof_ensure: symbols_from(symbol, first, first + span, i) &&
  entries_upto(weights, count, last, symbol, nbits, c, max_bits, i),
} {
  let s = byte_of(i)
  for k = first; k < first + span; {
    proof_assert avoided(weights, count, last, c, i, k)
    symbol[k] = s
    continue k + 1
  } where {
    proof_invariant: first <= k && k <= first + span,
    proof_invariant: symbol.length() == 2048,
    proof_invariant: symbols_from(symbol, first, k, i),
    proof_invariant: entries_upto(
      weights, count, last, symbol, nbits, c, max_bits, i,
    ),
  }
}

///|
/// The entries of symbol `i`, from `start[w]` for its weight `w`, are apart
/// from those of the symbols placed before it: those of the same weight and
/// the lighter ones lie below, the heavier ones above.
fn place_apart(
  weights : FixedArray[Int32],
  count : Int32,
  last : Int32,
  c : FixedArray[Int32],
  start : FixedArray[Int32],
  max_bits : Int32,
  i : Int32,
) -> Unit where {
  proof_require: apart_pre(weights, count, last, c, start, max_bits, i),
  proof_ensure: apart_upto(
    weights,
    count,
    last,
    c,
    i,
    start[weight_of(weights, count, last, i)],
  ),
} {

}

///|
/// `total_upto` grows with the weights, the counts being at least 0.
fn totals_grow(
  c : FixedArray[Int32],
) -> Unit where {
  proof_require: c.length() == 12 && counts_within(c, 256),
  proof_ensure: totals_mono(c),
} {
  for b = 0; b < 11; {
    total_step(c, b)
    continue b + 1
  } where {
    proof_invariant: 0 <= b && b <= 11,
    proof_invariant: totals_mono_upto(c, b),
  }
}

///|
/// `total_upto` is the sum it stands for, one weight at a time.
fn total_step(
  c : FixedArray[Int32],
  m : Int32,
) -> Unit where {
  proof_require: 0 <= m && m < 11,
  proof_ensure: total_upto(c, m + 1) ==
  total_upto(c, m) + share(c[m + 1], m + 1),
} {
  if m == 0 {
    proof_assert total_upto(c, 1) == total_upto(c, 0) + 1 * c[1]
  } else if m == 1 {
    proof_assert total_upto(c, 2) == total_upto(c, 1) + 2 * c[2]
  } else if m == 2 {
    proof_assert total_upto(c, 3) == total_upto(c, 2) + 4 * c[3]
  } else if m == 3 {
    proof_assert total_upto(c, 4) == total_upto(c, 3) + 8 * c[4]
  } else if m == 4 {
    proof_assert total_upto(c, 5) == total_upto(c, 4) + 16 * c[5]
  } else if m == 5 {
    proof_assert total_upto(c, 6) == total_upto(c, 5) + 32 * c[6]
  } else if m == 6 {
    proof_assert total_upto(c, 7) == total_upto(c, 6) + 64 * c[7]
  } else if m == 7 {
    proof_assert total_upto(c, 8) == total_upto(c, 7) + 128 * c[8]
  } else if m == 8 {
    proof_assert total_upto(c, 9) == total_upto(c, 8) + 256 * c[9]
  } else if m == 9 {
    proof_assert total_upto(c, 10) == total_upto(c, 9) + 512 * c[10]
  } else if m == 10 {
    proof_assert total_upto(c, 11) == total_upto(c, 10) + 1024 * c[11]
  }
}

///|
/// One more symbol of weight `w` takes 2^(w - 1) more entries, and more
/// symbols take more entries.
fn share_rules(
  w : Int32,
) -> Unit where {
  proof_require: 1 <= w && w <= 11,
  proof_ensure: share_next_all(w) && share_grows_all(w),
} {

}

///|
/// Every symbol's entries lie in the block of its weight.
fn all_blocks(
  weights : FixedArray[Int32],
  count : Int32,
  last : Int32,
  c : FixedArray[Int32],
  max_bits : Int32,
) -> Unit where {
  proof_require: blocks_pre(weights, count, last, c, max_bits),
  proof_ensure: blocks_all(weights, count, last, c, max_bits),
} {
  for s = 0; s < count + 1; {
    block_of(weights, count, last, c, max_bits, s)
    continue s + 1
  } where {
    proof_invariant: 0 <= s && s <= count + 1,
    proof_invariant: blocks_below(weights, count, last, c, max_bits, s),
  }
}

///|
/// Symbol `s`'s entries lie in the block of its weight.
fn block_of(
  weights : FixedArray[Int32],
  count : Int32,
  last : Int32,
  c : FixedArray[Int32],
  max_bits : Int32,
  s : Int32,
) -> Unit where {
  proof_require: blocks_pre(weights, count, last, c, max_bits) &&
  0 <= s &&
  s <= count,
  proof_ensure: weight_of(weights, count, last, s) == 0 ||
  in_block(
    weights,
    count,
    last,
    c,
    max_bits,
    s,
    first_entry(weights, count, last, c, s),
  ),
} {
  let w = if s == count { last } else { weights[s] }
  if w > 0 {
    if s < count {
      @proof_codes.count_step(weights, s)
      @proof_codes.count_grows(weights, w, s + 1, count)
    } else {
      @proof_codes.count_grows(weights, w, 0, count)
    }
    proof_assert @proof_codes.numof(weights, w, 0, s) + 1 <= c[w]
    proof_assert w <= max_bits
    total_step(c, w - 1)
    share_rules(w)
  }
}

///|
/// `share` is the product it stands for.
fn share_is(
  x : Int32,
  w : Int32,
) -> Unit where {
  proof_require: 1 <= w && w <= 11,
  proof_ensure: share(x, w) == x * @proof_bits.pow2(w - 1),
} {
  if w == 1 {
    proof_assert @proof_bits.pow2(0) == 1
  } else if w == 2 {
    proof_assert @proof_bits.pow2(1) == 2
  } else if w == 3 {
    proof_assert @proof_bits.pow2(2) == 4
  } else if w == 4 {
    proof_assert @proof_bits.pow2(3) == 8
  } else if w == 5 {
    proof_assert @proof_bits.pow2(4) == 16
  } else if w == 6 {
    proof_assert @proof_bits.pow2(5) == 32
  } else if w == 7 {
    proof_assert @proof_bits.pow2(6) == 64
  } else if w == 8 {
    proof_assert @proof_bits.pow2(7) == 128
  } else if w == 9 {
    proof_assert @proof_bits.pow2(8) == 256
  } else if w == 10 {
    proof_assert @proof_bits.pow2(9) == 512
  } else if w == 11 {
    proof_assert @proof_bits.pow2(10) == 1024
  }
}

///|
/// The sum of the weights from their counts is the sum of the weights.
fn sum_of_counts(
  c : FixedArray[Int32],
  weights : FixedArray[Int32],
  u : Int32,
) -> Unit where {
  proof_require: counted_weights(c, weights, u),
  proof_ensure: total_upto(c, 11) == weight_sum(weights, u),
} {
  proof_assert c[1] == @proof_codes.numof(weights, 1, 0, u)
  proof_assert c[2] == @proof_codes.numof(weights, 2, 0, u)
  proof_assert c[3] == @proof_codes.numof(weights, 3, 0, u)
  proof_assert c[4] == @proof_codes.numof(weights, 4, 0, u)
  proof_assert c[5] == @proof_codes.numof(weights, 5, 0, u)
  proof_assert c[6] == @proof_codes.numof(weights, 6, 0, u)
  proof_assert c[7] == @proof_codes.numof(weights, 7, 0, u)
  proof_assert c[8] == @proof_codes.numof(weights, 8, 0, u)
  proof_assert c[9] == @proof_codes.numof(weights, 9, 0, u)
  proof_assert c[10] == @proof_codes.numof(weights, 10, 0, u)
  proof_assert c[11] == @proof_codes.numof(weights, 11, 0, u)
}

///|
/// Weights whose shares add up to less than 2^max_bits weigh at most
/// max_bits.
fn lighter_than(
  c : FixedArray[Int32],
  max_bits : Int32,
) -> Unit where {
  proof_require: 1 <= max_bits &&
  max_bits <= 11 &&
  counts_within(c, 256) &&
  total_upto(c, 11) < @proof_bits.pow2(max_bits),
  proof_ensure: none_heavier(c, max_bits) &&
  total_upto(c, max_bits) == total_upto(c, 11),
} {
  if max_bits == 1 {
    proof_assert c[2] == 0
    proof_assert c[3] == 0
    proof_assert c[4] == 0
    proof_assert c[5] == 0
    proof_assert c[6] == 0
    proof_assert c[7] == 0
    proof_assert c[8] == 0
    proof_assert c[9] == 0
    proof_assert c[10] == 0
    proof_assert c[11] == 0
  } else if max_bits == 2 {
    proof_assert c[3] == 0
    proof_assert c[4] == 0
    proof_assert c[5] == 0
    proof_assert c[6] == 0
    proof_assert c[7] == 0
    proof_assert c[8] == 0
    proof_assert c[9] == 0
    proof_assert c[10] == 0
    proof_assert c[11] == 0
  } else if max_bits == 3 {
    proof_assert c[4] == 0
    proof_assert c[5] == 0
    proof_assert c[6] == 0
    proof_assert c[7] == 0
    proof_assert c[8] == 0
    proof_assert c[9] == 0
    proof_assert c[10] == 0
    proof_assert c[11] == 0
  } else if max_bits == 4 {
    proof_assert c[5] == 0
    proof_assert c[6] == 0
    proof_assert c[7] == 0
    proof_assert c[8] == 0
    proof_assert c[9] == 0
    proof_assert c[10] == 0
    proof_assert c[11] == 0
  } else if max_bits == 5 {
    proof_assert c[6] == 0
    proof_assert c[7] == 0
    proof_assert c[8] == 0
    proof_assert c[9] == 0
    proof_assert c[10] == 0
    proof_assert c[11] == 0
  } else if max_bits == 6 {
    proof_assert c[7] == 0
    proof_assert c[8] == 0
    proof_assert c[9] == 0
    proof_assert c[10] == 0
    proof_assert c[11] == 0
  } else if max_bits == 7 {
    proof_assert c[8] == 0
    proof_assert c[9] == 0
    proof_assert c[10] == 0
    proof_assert c[11] == 0
  } else if max_bits == 8 {
    proof_assert c[9] == 0
    proof_assert c[10] == 0
    proof_assert c[11] == 0
  } else if max_bits == 9 {
    proof_assert c[10] == 0
    proof_assert c[11] == 0
  } else if max_bits == 10 {
    proof_assert c[11] == 0
  } else if max_bits == 11 {
    ()
  }
}

///|
/// What is left of 2^max_bits after a total of max_bits bits is at most
/// half of it.
fn left_bound(
  total : Int32,
  max_bits : Int32,
) -> Unit where {
  proof_require: 0 < total &&
  1 <= max_bits &&
  max_bits <= 11 &&
  max_bits == bits_of(total),
  proof_ensure: 1 <= @proof_bits.pow2(max_bits) - total &&
  @proof_bits.pow2(max_bits) - total <= @proof_bits.pow2(max_bits - 1),
} {
  if max_bits == 1 {
    proof_assert 1 <= total && total < 2
  } else if max_bits == 2 {
    proof_assert 2 <= total && total < 4
  } else if max_bits == 3 {
    proof_assert 4 <= total && total < 8
  } else if max_bits == 4 {
    proof_assert 8 <= total && total < 16
  } else if max_bits == 5 {
    proof_assert 16 <= total && total < 32
  } else if max_bits == 6 {
    proof_assert 32 <= total && total < 64
  } else if max_bits == 7 {
    proof_assert 64 <= total && total < 128
  } else if max_bits == 8 {
    proof_assert 128 <= total && total < 256
  } else if max_bits == 9 {
    proof_assert 256 <= total && total < 512
  } else if max_bits == 10 {
    proof_assert 512 <= total && total < 1024
  } else if max_bits == 11 {
    proof_assert 1024 <= total && total < 2048
  }
}

///|
/// `bits_of` is the number of bits.
fn bits_between(
  total : Int32,
  b : Int32,
) -> Unit where {
  proof_require: 1 <= b &&
  b <= 11 &&
  @proof_bits.pow2(b - 1) <= total &&
  total < @proof_bits.pow2(b),
  proof_ensure: bits_of(total) == b,
} {
  if b == 1 {
    proof_assert 1 <= total && total < 2
  } else if b == 2 {
    proof_assert 2 <= total && total < 4
  } else if b == 3 {
    proof_assert 4 <= total && total < 8
  } else if b == 4 {
    proof_assert 8 <= total && total < 16
  } else if b == 5 {
    proof_assert 16 <= total && total < 32
  } else if b == 6 {
    proof_assert 32 <= total && total < 64
  } else if b == 7 {
    proof_assert 64 <= total && total < 128
  } else if b == 8 {
    proof_assert 128 <= total && total < 256
  } else if b == 9 {
    proof_assert 256 <= total && total < 512
  } else if b == 10 {
    proof_assert 512 <= total && total < 1024
  } else if b == 11 {
    proof_assert 1024 <= total && total < 2048
  }
}

///|
fn bits_past_11(
  total : Int32,
) -> Unit where {
  proof_require: 2048 <= total,
  proof_ensure: bits_of(total) == 12,
} {

}

///|
/// `implied_of` takes 2^k to k + 1.
fn implied_at(
  k : Int32,
) -> Unit where {
  proof_require: 0 <= k && k <= 10,
  proof_ensure: implied_of(@proof_bits.pow2(k)) == k + 1,
} {
  if k == 0 {
    proof_assert @proof_bits.pow2(0) == 1
  } else if k == 1 {
    proof_assert @proof_bits.pow2(1) == 2
  } else if k == 2 {
    proof_assert @proof_bits.pow2(2) == 4
  } else if k == 3 {
    proof_assert @proof_bits.pow2(3) == 8
  } else if k == 4 {
    proof_assert @proof_bits.pow2(4) == 16
  } else if k == 5 {
    proof_assert @proof_bits.pow2(5) == 32
  } else if k == 6 {
    proof_assert @proof_bits.pow2(6) == 64
  } else if k == 7 {
    proof_assert @proof_bits.pow2(7) == 128
  } else if k == 8 {
    proof_assert @proof_bits.pow2(8) == 256
  } else if k == 9 {
    proof_assert @proof_bits.pow2(9) == 512
  } else if k == 10 {
    proof_assert @proof_bits.pow2(10) == 1024
  }
}

///|
/// `implied_of` takes what is not a power of 2 to 0.
fn implied_none(
  left : Int32,
) -> Unit where {
  proof_require: not_power_below(left, 11),
  proof_ensure: implied_of(left) == 0,
} {
  proof_assert @proof_bits.pow2(0) != left
  proof_assert @proof_bits.pow2(1) != left
  proof_assert @proof_bits.pow2(2) != left
  proof_assert @proof_bits.pow2(3) != left
  proof_assert @proof_bits.pow2(4) != left
  proof_assert @proof_bits.pow2(5) != left
  proof_assert @proof_bits.pow2(6) != left
  proof_assert @proof_bits.pow2(7) != left
  proof_assert @proof_bits.pow2(8) != left
  proof_assert @proof_bits.pow2(9) != left
  proof_assert @proof_bits.pow2(10) != left
}

///|
/// The implied weight of what is left of 2^max_bits is at most max_bits.
fn implied_fits(
  left : Int32,
  max_bits : Int32,
) -> Unit where {
  proof_require: 1 <= max_bits &&
  max_bits <= 11 &&
  1 <= left &&
  left <= @proof_bits.pow2(max_bits - 1) &&
  implied_of(left) > 0,
  proof_ensure: implied_of(left) <= max_bits &&
  @proof_bits.pow2(implied_of(left) - 1) == left,
} {
  if left == 1 {
    proof_assert implied_of(left) == 1
  } else if left == 2 {
    proof_assert implied_of(left) == 2
  } else if left == 4 {
    proof_assert implied_of(left) == 3
  } else if left == 8 {
    proof_assert implied_of(left) == 4
  } else if left == 16 {
    proof_assert implied_of(left) == 5
  } else if left == 32 {
    proof_assert implied_of(left) == 6
  } else if left == 64 {
    proof_assert implied_of(left) == 7
  } else if left == 128 {
    proof_assert implied_of(left) == 8
  } else if left == 256 {
    proof_assert implied_of(left) == 9
  } else if left == 512 {
    proof_assert implied_of(left) == 10
  } else if left == 1024 {
    proof_assert implied_of(left) == 11
  }
}
