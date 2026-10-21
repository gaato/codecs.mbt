// Length-limited Huffman codes, as DEFLATE and Brotli encoders build them:
// code lengths from symbol frequencies, then the canonical codes the lengths
// define.

///|
/// Sets `lengths[0..n)` to Huffman code lengths for the frequencies
/// `freqs[0..n)`, none longer than `max_bits`. Unused symbols get 0 and a
/// lone used symbol gets 1; two or more used symbols get a complete code.
/// When the optimal code is too long, the frequencies are floored at 2, 4,
/// 8, ... until it fits, as the reference Brotli encoder does. Needs at most
/// `1 << max_bits` used symbols.
pub fn code_lengths(
  freqs : FixedArray[Int32],
  n : Int32,
  max_bits : Int32,
  lengths : FixedArray[Int32],
) -> Unit {
  lengths.fill(0, end=n)
  let used = []
  for s in 0..<n {
    if freqs[s] > 0 {
      used.push(s)
    }
  }
  let m = used.length()
  if m == 0 {
    return
  }
  if m == 1 {
    lengths[used[0]] = 1
    return
  }
  // Leaves are nodes 0..m-1 by increasing weight; internal nodes follow in
  // the order they are made, which is also by increasing weight.
  let weight = FixedArray::make(2 * m - 1, 0)
  let parent = FixedArray::make(2 * m - 1, 0)
  let depth = FixedArray::make(2 * m - 1, 0)
  for floor = 1; ; floor = floor * 2 {
    used.sort_by((a, b) => {
      let wa = freqs[a].max(floor)
      let wb = freqs[b].max(floor)
      if wa != wb {
        wa.compare(wb)
      } else {
        a.compare(b)
      }
    })
    for i in 0..<m {
      weight[i] = freqs[used[i]].max(floor)
    }
    let mut leaf = 0
    let mut node = m
    for next in m..<(2 * m - 1) {
      // Join the two lightest nodes; on a tie, the leaf.
      weight[next] = 0
      for _ in 0..<2 {
        let child = if leaf < m &&
          (node >= next || weight[leaf] <= weight[node]) {
          leaf += 1
          leaf - 1
        } else {
          node += 1
          node - 1
        }
        weight[next] += weight[child]
        parent[child] = next
      }
    }
    depth[2 * m - 2] = 0
    let mut longest = 0
    for i = 2 * m - 3; i >= 0; i = i - 1 {
      depth[i] = depth[parent[i]] + 1
      if i < m {
        longest = longest.max(depth[i])
      }
    }
    if longest <= max_bits {
      for i in 0..<m {
        lengths[used[i]] = depth[i]
      }
      return
    }
  }
}

///|
/// Sets `codes[0..n)` to the canonical codes of the code lengths
/// `lengths[0..n)` (RFC 1951 section 3.2.2), bit-reversed: written least
/// significant bit first, as DEFLATE and Brotli pack their bits, each code
/// comes out most significant bit first. Symbols of length 0 get 0.
pub fn canonical_codes(
  lengths : FixedArray[Int32],
  n : Int32,
  codes : FixedArray[Int32],
) -> Unit {
  canonical_into(
    lengths,
    n,
    codes,
    FixedArray::make(32, 0),
    FixedArray::make(32, 0),
  )
}

///|
/// `canonical_codes` with its scratch space: `count`, the codes of each
/// length, and `next`, the next code of each length, both 32 zeros.
fn canonical_into(
  lengths : FixedArray[Int32],
  n : Int32,
  codes : FixedArray[Int32],
  count : FixedArray[Int32],
  next : FixedArray[Int32],
) -> Unit where {
  proof_require: canonical_pre(lengths, n, codes, count, next),
  proof_ensure: canonical_post(lengths, n, codes, count),
} {
  // In three steps, each proved apart, so that the facts of one do not
  // crowd the solvers' context in the next.
  count_codes(lengths, n, count)
  first_codes(count, next)
  @proof_codes.reverse_facts(0)
  assign_codes(lengths, n, codes, count, next)
}

///|
/// Counts the codes of each length into `count` (32 zeros): `count[0]`
/// stays 0.
fn count_codes(
  lengths : FixedArray[Int32],
  n : Int32,
  count : FixedArray[Int32],
) -> Unit where {
  proof_require: @proof_codes.lengths_within(lengths, n, 15) &&
  count.length() == 32 &&
  zeros(count),
  proof_ensure: counted_codes(count, lengths, n),
} {
  for s = 0; s < n; {
    count[lengths[s]] = count[lengths[s]] + 1
    continue s + 1
  } where {
    proof_invariant: 0 <= s && s <= n,
    proof_invariant: count.length() == 32,
    proof_invariant: @proof_codes.counted(count, lengths, s),
    proof_invariant: none_past_15(count),
    proof_invariant: nonneg_upto(count, 31),
  }
  count[0] = 0
}

///|
/// Sets `next[1..32)` to the first code of each length (RFC 1951 section
/// 3.2.2, step 2).
fn first_codes(
  count : FixedArray[Int32],
  next : FixedArray[Int32],
) -> Unit where {
  proof_require: first_codes_pre(count, next),
  proof_ensure: firsts_upto(next, count, 15) && nonneg_upto(next, 31),
} {
  for len = 1; len < 32; {
    proof_assert len == 1 ||
      len > 16 ||
      next[len - 1] == @proof_codes.first_code(count, len - 1)
    next[len] = 2 * (next[len - 1] + count[len - 1])
    if len == 1 {
      @proof_codes.first_code_one(count)
    } else if len <= 15 {
      @proof_codes.first_code_step(count, len - 1)
    }
    continue len + 1
  } where {
    proof_invariant: 1 <= len && len <= 32,
    proof_invariant: next.length() == 32,
    proof_invariant: firsts_upto(next, count, len - 1),
    proof_invariant: nonneg_upto(next, len - 1),
    proof_invariant: next[0] == 0,
  }
}

///|
/// Gives each symbol the next code of its length, reversed (RFC 1951
/// section 3.2.2, step 3).
fn assign_codes(
  lengths : FixedArray[Int32],
  n : Int32,
  codes : FixedArray[Int32],
  count : FixedArray[Int32],
  next : FixedArray[Int32],
) -> Unit where {
  proof_require: assign_pre(lengths, n, codes, count, next),
  proof_ensure: codes_upto(lengths, codes, count, n),
} {
  for s = 0; s < n; {
    let len = lengths[s]
    proof_assert 0 <= len && len <= 15
    if len == 0 {
      codes[s] = 0
    } else {
      proof_assert next[len] ==
        @proof_codes.first_code(count, len) +
        @proof_codes.numof(lengths, len, 0, s)
      proof_assert next[len] == @proof_codes.canonical(count, lengths, s)
      proof_assert next[len] >= 0
      codes[s] = reverse_bits(next[len], len)
      next[len] = next[len] + 1
    }
    proof_assert code_of(lengths, codes, count, s)
    continue s + 1
  } where {
    proof_invariant: 0 <= s && s <= n,
    proof_invariant: next.length() == 32,
    proof_invariant: next_codes(next, count, lengths, s),
    proof_invariant: nonneg_upto(next, 15),
    proof_invariant: codes_upto(lengths, codes, count, s),
  }
}

///|
/// The low `n` bits of `code` in reverse order.
pub fn reverse_bits(
  code : Int32,
  n : Int32,
) -> Int32 where {
  proof_require: reverse_pre(code, n),
  proof_ensure: result => reverse_post(code, n, result),
} {
  for i = 0, c = code, r = 0; i < n; {
    continue i + 1, @proof_bits.shr(c, 1), 2 * r + @proof_bits.low_bits(c, 1)
  } nobreak {
    r
  } where {
    proof_invariant: reverse_inv(code, n, i, c, r),
  }
}
