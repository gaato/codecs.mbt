// google/brotli v1.2.1 entropy_encode_static.h and brotli_bit_stream.c.
// Copyright 2015 Google Inc.; MIT, see LICENSE-encoder.

///|
priv struct LowTables {
  length_depth : FixedArray[Int32]
  length_bits : FixedArray[Int32]
  zero_depth : FixedArray[Int32]
  zero_bits : FixedArray[Int32]
  nonzero_depth : FixedArray[Int32]
  nonzero_bits : FixedArray[Int32]
  command : RefCode
  distance : RefCode
}

///|
fn LowTables::new() -> LowTables {
  {
    length_depth: low_length_depth(),
    length_bits: low_length_bits(),
    zero_depth: low_zero_depth(),
    zero_bits: low_zero_bits(),
    nonzero_depth: low_nonzero_depth(),
    nonzero_bits: low_nonzero_bits(),
    command: {
      depths: low_static_command_depth(),
      bits: low_static_command_bits(),
    },
    distance: {
      depths: low_static_distance_depth(),
      bits: low_static_distance_bits(),
    },
  }
}

///|
fn low_symbols(depths : FixedArray[Int32]) -> FixedArray[Int32] {
  let count = FixedArray::make(16, 0)
  for d in depths {
    count[d] += 1
  }
  count[0] = 0
  let next = FixedArray::make(16, 0)
  for i in 1..<16 {
    next[i] = (next[i - 1] + count[i - 1]) << 1
  }
  FixedArray::makei(depths.length(), i => {
    let d = depths[i]
    if d == 0 {
      0
    } else {
      let mut v = next[d]
      let mut r = 0
      for _ in 0..<d {
        r = (r << 1) | (v & 1)
        v = v >> 1
      }
      next[d] += 1
      r
    }
  })
}

///|
fn low_fast_code(hist : FixedArray[Int32]) -> RefCode {
  let n = hist.length()
  let depths = FixedArray::make(n, 0)
  let counts = FixedArray::make(2 * n + 1, 0)
  let left = FixedArray::make(2 * n + 1, -1)
  let right = FixedArray::make(2 * n + 1, 0)
  let mut floor = 1
  for ;; {
    let leaves : Array[Int32] = []
    for i = n - 1; i >= 0; i = i - 1 {
      if hist[i] > 0 {
        leaves.push(i)
      }
    }
    let m = leaves.length()
    if m <= 1 {
      if m == 1 {
        depths[leaves[0]] = 1
      }
      break
    }
    // Fast's comparator uses population alone; its Shell-sort tie order
    // differs from the ordinary Huffman builder's symbol tie breaker.
    let gaps = if m < 13 {
      [1]
    } else if m < 57 {
      [23, 10, 4, 1]
    } else {
      [132, 57, 23, 10, 4, 1]
    }
    for gap in gaps {
      for i in gap..<m {
        let v = leaves[i]
        let mut j = i
        while j >= gap && hist[v].max(floor) < hist[leaves[j - gap]].max(floor) {
          leaves[j] = leaves[j - gap]
          j -= gap
        }
        leaves[j] = v
      }
    }
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
        let k = a
        a += 1
        k
      } else {
        let k = b
        b += 1
        k
      }
      let r = if counts[a] <= counts[b] {
        let k = a
        a += 1
        k
      } else {
        let k = b
        b += 1
        k
      }
      counts[at] = counts[l] + counts[r]
      left[at] = l
      right[at] = r
      counts[at + 1] = 0x7fffffff
    }
    let stack = [(2 * m - 1, 0)]
    let mut fits = true
    while !stack.is_empty() {
      let (at, d) = stack.pop().unwrap()
      if d > 14 {
        fits = false
        break
      }
      if left[at] < 0 {
        depths[right[at]] = d
      } else {
        stack.push((right[at], d + 1))
        stack.push((left[at], d + 1))
      }
    }
    if fits {
      break
    }
    depths.fill(0)
    floor *= 2
  }
  { depths, bits: low_symbols(depths), }
}

///|
fn LowBits::fast_tree(
  self : LowBits,
  tables : LowTables,
  hist : FixedArray[Int32],
  max_bits : Int32,
) -> RefCode {
  let code = low_fast_code(hist)
  let used : Array[Int32] = []
  for i in 0..<hist.length() {
    if hist[i] > 0 {
      used.push(i)
    }
  }
  if used.length() <= 1 {
    let s = if used.is_empty() { 0 } else { used[0] }
    self.write(4, 1)
    self.write(max_bits, s)
    code.depths[s] = 0
    code.bits[s] = 0
  } else if used.length() <= 4 {
    for i in 0..<used.length() {
      for j in (i + 1)..<used.length() {
        if code.depths[used[j]] < code.depths[used[i]] {
          let t = used[i]
          used[i] = used[j]
          used[j] = t
        }
      }
    }
    self.write(2, 1)
    self.write(2, used.length() - 1)
    for s in used {
      self.write(max_bits, s)
    }
    if used.length() == 4 {
      self.write(1, if code.depths[used[0]] == 1 { 1 } else { 0 })
    }
  } else {
    self.write(32, 0x55555554)
    self.write(8, 0xff)
    let end = used[used.length() - 1] + 1
    let mut previous = 8
    let mut i = 0
    while i < end {
      let value = code.depths[i]
      let mut reps = 1
      while i + reps < end && code.depths[i + reps] == value {
        reps += 1
      }
      i += reps
      if value == 0 {
        self.write(tables.zero_depth[reps], tables.zero_bits[reps])
      } else {
        if previous != value {
          self.write(tables.length_depth[value], tables.length_bits[value])
          reps -= 1
        }
        if reps < 3 {
          for _ in 0..<reps {
            self.write(tables.length_depth[value], tables.length_bits[value])
          }
        } else {
          reps -= 3
          self.write(tables.nonzero_depth[reps], tables.nonzero_bits[reps])
        }
        previous = value
      }
    }
  }
  code
}

///|
fn LowBits::ordinary_tree(self : LowBits, hist : FixedArray[Int32]) -> RefCode {
  let writer = @bits.BitPacker()
  let code = ref_write_code(writer, hist)
  let n = writer.position()
  writer.align()
  let data = FixedArray::make((n + 7) / 8, b'\x00')
  let _ = writer.drain(data.mut_view(), 0)
  for i in 0..<(n / 8) {
    self.write(8, data[i].to_int())
  }
  if (n & 7) != 0 {
    self.write(n & 7, data[n / 8].to_int())
  }
  code
}
