// Port of google/brotli v1.2.1 c/enc/entropy_encode.c and brotli_bit_stream.c.
// Copyright 2010, 2013 Google Inc. Distributed under the MIT license;
// see LICENSE-encoder.

///|
priv struct RefCode {
  depths : FixedArray[Int32]
  bits : FixedArray[Int32]
}

///|
// Stable leaf ordering and leaf-before-parent ties are part of the oracle.
fn ref_code(hist : FixedArray[Int32], limit~ : Int32 = 15) -> RefCode {
  let n = hist.length()
  let depths = FixedArray::make(n, 0)
  let counts = FixedArray::make(2 * n + 1, 0)
  let left = FixedArray::make(2 * n + 1, -1)
  let right = FixedArray::make(2 * n + 1, 0)
  let mut floor = 1
  for ;; {
    let leaves = Array()
    for i in 0..<n {
      if hist[i] != 0 {
        leaves.push(i)
      }
    }
    let m = leaves.length()
    if m == 0 {
      break
    }
    if m == 1 {
      depths[leaves[0]] = 1
      break
    }
    leaves.sort_by((a, b) => {
      let ca = hist[a].max(floor)
      let cb = hist[b].max(floor)
      if ca != cb {
        ca.compare(cb)
      } else {
        b.compare(a)
      }
    })
    for i in 0..<m {
      counts[i] = hist[leaves[i]].max(floor)
      left[i] = -1
      right[i] = leaves[i]
    }
    counts[m] = 0x7fffffff
    counts[m + 1] = 0x7fffffff
    let mut a = 0
    let mut b = m + 1
    for at in (m + 1)..<(2 * m) {
      let l = if counts[a] <= counts[b] {
        let i = a
        a += 1
        i
      } else {
        let i = b
        b += 1
        i
      }
      let r = if counts[a] <= counts[b] {
        let i = a
        a += 1
        i
      } else {
        let i = b
        b += 1
        i
      }
      counts[at] = counts[l] + counts[r]
      left[at] = l
      right[at] = r
      counts[at + 1] = 0x7fffffff
    }
    let stack = [(2 * m - 1, 0)]
    let mut fits = true
    while !stack.is_empty() {
      let (at, depth) = stack.pop().unwrap()
      if depth > limit {
        fits = false
        break
      }
      if left[at] < 0 {
        depths[right[at]] = depth
      } else {
        stack.push((right[at], depth + 1))
        stack.push((left[at], depth + 1))
      }
    }
    if fits {
      break
    }
    depths.fill(0)
    floor *= 2
  }
  let count = FixedArray::make(16, 0)
  for d in depths {
    count[d] += 1
  }
  count[0] = 0
  let next = FixedArray::make(16, 0)
  for i in 1..<16 {
    next[i] = (next[i - 1] + count[i - 1]) << 1
  }
  let bits = FixedArray::make(n, 0)
  for i in 0..<n {
    let d = depths[i]
    if d > 0 {
      let mut value = next[d]
      let mut reversed = 0
      for _ in 0..<d {
        reversed = (reversed << 1) | (value & 1)
        value = value >> 1
      }
      bits[i] = reversed
      next[d] += 1
    }
  }
  { depths, bits, }
}

///|
fn RefCode::write(self : RefCode, w : @bits.BitPacker, symbol : Int32) -> Unit {
  w.write(self.depths[symbol], self.bits[symbol])
}

///|
fn ref_write_code(w : @bits.BitPacker, hist : FixedArray[Int32]) -> RefCode {
  let code = ref_code(hist)
  let used = Array()
  for i in 0..<hist.length() {
    if hist[i] > 0 {
      used.push(i)
    }
  }
  let nbits = 32 - (hist.length() - 1).clz()
  if used.length() <= 1 {
    let s = if used.is_empty() { 0 } else { used[0] }
    w.write(4, 1)
    w.write(nbits, s)
    code.depths[s] = 0
    code.bits[s] = 0
  } else if used.length() <= 4 {
    // The reference uses pairwise swaps, not a stable sort.
    for i in 0..<used.length() {
      for j in (i + 1)..<used.length() {
        if code.depths[used[j]] < code.depths[used[i]] {
          let t = used[i]
          used[i] = used[j]
          used[j] = t
        }
      }
    }
    w.write(2, 1)
    w.write(2, used.length() - 1)
    for s in used {
      w.write(nbits, s)
    }
    if used.length() == 4 {
      w.write(1, if code.depths[used[0]] == 1 { 1 } else { 0 })
    }
  } else {
    ref_write_complex(w, code.depths)
  }
  code
}

///|
fn ref_write_complex(w : @bits.BitPacker, depths : FixedArray[Int32]) -> Unit {
  let mut end = depths.length()
  while end > 0 && depths[end - 1] == 0 {
    end -= 1
  }
  let reps_sum = [0, 0]
  let reps_count = [1, 1]
  let mut i = 0
  while i < end {
    let v = depths[i]
    let mut run = 1
    while i + run < end && depths[i + run] == v {
      run += 1
    }
    let k = if v == 0 { 0 } else { 1 }
    if run >= (if v == 0 { 3 } else { 4 }) {
      reps_sum[k] += run
      reps_count[k] += 1
    }
    i += run
  }
  let use_zero = depths.length() > 50 && reps_sum[0] > 2 * reps_count[0]
  let use_nonzero = depths.length() > 50 && reps_sum[1] > 2 * reps_count[1]
  let syms = Array()
  let extras = Array()
  let mut prev = 8
  i = 0
  while i < end {
    let v = depths[i]
    let mut run = 1
    if (v == 0 && use_zero) || (v != 0 && use_nonzero) {
      while i + run < end && depths[i + run] == v {
        run += 1
      }
    }
    i += run
    if v != 0 && prev != v {
      syms.push(v)
      extras.push(0)
      run -= 1
    }
    if run == (if v == 0 { 11 } else { 7 }) {
      syms.push(v)
      extras.push(0)
      run -= 1
    }
    if run < 3 {
      for _ in 0..<run {
        syms.push(v)
        extras.push(0)
      }
    } else {
      let start = syms.length()
      let bits = if v == 0 { 3 } else { 2 }
      run -= 3
      for ;; {
        syms.push(if v == 0 { 17 } else { 16 })
        extras.push(run & ((1 << bits) - 1))
        run = run >> bits
        if run == 0 {
          break
        }
        run -= 1
      }
      for a = start, b = syms.length() - 1; a < b; a = a + 1, b = b - 1 {
        let s = syms[a]
        syms[a] = syms[b]
        syms[b] = s
        let e = extras[a]
        extras[a] = extras[b]
        extras[b] = e
      }
    }
    if v != 0 {
      prev = v
    }
  }
  let hist = FixedArray::make(18, 0)
  for s in syms {
    hist[s] += 1
  }
  let code = ref_code(hist, limit=5)
  let mut count = 0
  let mut only = 0
  for s in 0..<18 {
    if hist[s] > 0 {
      count += 1
      only = s
    }
  }
  let mut end = 18
  if count > 1 {
    while code.depths[code_length_order[end - 1]] == 0 {
      end -= 1
    }
  }
  let skip = if code.depths[1] != 0 || code.depths[2] != 0 {
    0
  } else if code.depths[3] != 0 {
    2
  } else {
    3
  }
  w.write(2, skip)
  for j in skip..<end {
    let d = code.depths[code_length_order[j]]
    w.write(code_length_code_bits[d], code_length_code[d])
  }
  if count == 1 {
    code.depths[only] = 0
  }
  for j in 0..<syms.length() {
    let s = syms[j]
    code.write(w, s)
    if s >= 16 {
      w.write(if s == 16 { 2 } else { 3 }, extras[j])
    }
  }
}

///|
fn ref_optimize_counts(counts : FixedArray[Int32]) -> Unit {
  let mut nonzeros = 0
  for c in counts {
    if c != 0 {
      nonzeros += 1
    }
  }
  if nonzeros < 16 {
    return
  }
  let mut n = counts.length()
  while n > 0 && counts[n - 1] == 0 {
    n -= 1
  }
  let mut smallest = 1 << 30
  for i in 0..<n {
    if counts[i] != 0 {
      smallest = smallest.min(counts[i])
    }
  }
  if smallest < 4 && n - nonzeros < 6 {
    for i in 1..<(n - 1) {
      if counts[i - 1] != 0 && counts[i] == 0 && counts[i + 1] != 0 {
        counts[i] = 1
      }
    }
  }
  if nonzeros < 28 {
    return
  }
  let good = FixedArray::make(n, false)
  let mut start = 0
  while start < n {
    let v = counts[start]
    let mut end = start + 1
    while end < n && counts[end] == v {
      end += 1
    }
    if end - start >= (if v == 0 { 5 } else { 7 }) {
      for j in start..<end {
        good[j] = true
      }
    }
    start = end
  }
  let mut stride = 0
  let mut sum = 0
  let mut limit = 256 * (counts[0] + counts[1] + counts[2]) / 3 + 420
  for i in 0..<=n {
    if i == n ||
      good[i] ||
      (i != 0 && good[i - 1]) ||
      256 * counts[i] - limit < -1240 ||
      256 * counts[i] - limit >= 1240 {
      if stride >= 4 || (stride >= 3 && sum == 0) {
        let count = if sum == 0 {
          0
        } else {
          ((sum + stride / 2) / stride).max(1)
        }
        for j in (i - stride)..<i {
          counts[j] = count
        }
      }
      stride = 0
      sum = 0
      limit = if i < n - 2 {
        256 * (counts[i] + counts[i + 1] + counts[i + 2]) / 3 + 420
      } else if i < n {
        256 * counts[i]
      } else {
        0
      }
    }
    stride += 1
    if i != n {
      sum += counts[i]
      if stride >= 4 {
        limit = (256 * sum + stride / 2) / stride
      }
      if stride == 4 {
        limit += 120
      }
    }
  }
}
