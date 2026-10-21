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
  let count = FixedArray::make(32, 0)
  for s in 0..<n {
    count[lengths[s]] += 1
  }
  count[0] = 0
  let next = FixedArray::make(32, 0)
  for len in 1..<32 {
    next[len] = (next[len - 1] + count[len - 1]) << 1
  }
  for s in 0..<n {
    let len = lengths[s]
    if len == 0 {
      codes[s] = 0
    } else {
      codes[s] = reverse_bits(next[len], len)
      next[len] += 1
    }
  }
}

///|
/// The low `n` bits of `code` in reverse order.
pub fn reverse_bits(code : Int32, n : Int32) -> Int32 {
  for i = 0, c = code, r = 0; i < n; {
    continue i + 1, c >> 1, (r << 1) | (c & 1)
  } nobreak {
    r
  }
}
