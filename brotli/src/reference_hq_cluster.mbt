// Port of google/brotli v1.2.1 c/enc/{bit_cost,cluster}_inc.h.
// Copyright 2013 Google Inc.; MIT, see LICENSE-encoder.

///|
priv struct HqHistogram {
  data : FixedArray[Int32]
  mut total : Int32
  mut cost : Double
}

///|
fn HqHistogram::new(alphabet : Int32) -> HqHistogram {
  { data: FixedArray::make(alphabet, 0), total: 0, cost: 0.0, }
}

///|
fn HqHistogram::clear(self : HqHistogram) -> Unit {
  self.data.fill(0)
  self.total = 0
  self.cost = 0.0
}

///|
fn HqHistogram::add(self : HqHistogram, symbol : Int32) -> Unit {
  self.data[symbol] += 1
  self.total += 1
}

///|
fn HqHistogram::merge(self : HqHistogram, other : HqHistogram) -> Unit {
  for i in 0..<self.data.length() {
    self.data[i] += other.data[i]
  }
  self.total += other.total
}

///|
fn HqHistogram::assign(self : HqHistogram, other : HqHistogram) -> Unit {
  for i in 0..<self.data.length() {
    self.data[i] = other.data[i]
  }
  self.total = other.total
  self.cost = other.cost
}

///|
fn HqHistogram::population(self : HqHistogram, memory? : HqMemory) -> Double {
  let mark = hq_memory_mark(memory)
  defer hq_memory_restore(memory, mark)
  if self.total == 0 {
    return 12.0
  }
  let counts : Array[Int32] = []
  for count in self.data {
    if count > 0 {
      counts.push(count)
      if counts.length() == 5 {
        break
      }
    }
  }
  hq_memory_add(memory, 4L * counts.capacity().to_int64())
  if counts.length() == 1 {
    return 12.0
  }
  if counts.length() == 2 {
    return 20.0 + self.total.to_double()
  }
  if counts.length() == 3 {
    return (28 + 2 * self.total - counts[0].max(counts[1]).max(counts[2])).to_double()
  }
  if counts.length() == 4 {
    for i in 0..<4 {
      for j in (i + 1)..<4 {
        if counts[j] > counts[i] {
          let t = counts[i]
          counts[i] = counts[j]
          counts[j] = t
        }
      }
    }
    let h23 = counts[2] + counts[3]
    return (37 + 3 * h23 + 2 * (counts[0] + counts[1]) - h23.max(counts[0])).to_double()
  }
  let depths = FixedArray::make(18, 0)
  hq_memory_add(memory, 4L * depths.length().to_int64())
  let logtotal = ref_log(self.total)
  let mut bits = 0.0
  let mut max_depth = 1
  let mut i = 0
  while i < self.data.length() {
    let n = self.data[i]
    if n > 0 {
      let logp = logtotal - ref_log(n)
      let depth = (logp + 0.5).to_int().min(15)
      bits += n.to_double() * logp
      max_depth = max_depth.max(depth)
      depths[depth] += 1
      i += 1
    } else {
      let mut reps = 1
      while i + reps < self.data.length() && self.data[i + reps] == 0 {
        reps += 1
      }
      i += reps
      if i == self.data.length() {
        break
      }
      if reps < 3 {
        depths[0] += reps
      } else {
        reps -= 2
        while reps > 0 {
          depths[17] += 1
          bits += 3.0
          reps = reps >> 3
        }
      }
    }
  }
  bits + (18 + 2 * max_depth).to_double() + ref_entropy(depths)
}

///|
priv struct HqPair {
  a : Int32
  b : Int32
  diff : Double
  combo : Double
}

///|
fn HqPair::less(self : HqPair, other : HqPair) -> Bool {
  if self.diff != other.diff {
    self.diff > other.diff
  } else {
    self.b - self.a > other.b - other.a
  }
}

///|
fn hq_max_pairs(clusters : Int32) -> Int32 {
  // Upstream uses size_t. An initial block partition can have more than
  // 65536 clusters, so its all-pair count must not overflow Int32 before
  // applying the linear cap.
  let n = clusters.to_int64()
  (64L * n).min(n / 2L * n).to_int()
}

///|
fn hq_compare(
  out : Array[HqHistogram],
  tmp : HqHistogram,
  sizes : FixedArray[Int32],
  ia : Int32,
  ib : Int32,
  limit : Int32,
  pairs : Array[HqPair],
  memory? : HqMemory,
) -> Unit {
  if ia == ib {
    return
  }
  let a = ia.min(ib)
  let b = ia.max(ib)
  let sa = sizes[a]
  let sb = sizes[b]
  let diff = 0.5 *
    (
      sa.to_double() * ref_log(sa) +
      sb.to_double() * ref_log(sb) -
      (sa + sb).to_double() * ref_log(sa + sb)
    ) -
    out[a].cost -
    out[b].cost
  let combo = if out[a].total == 0 {
    out[b].cost
  } else if out[b].total == 0 {
    out[a].cost
  } else {
    tmp.assign(out[a])
    tmp.merge(out[b])
    let cost = tmp.population(memory?)
    let threshold = if pairs.is_empty() {
      1.0e99
    } else {
      pairs[0].diff.max(0.0)
    }
    if cost >= threshold - diff {
      return
    }
    cost
  }
  let pair = HqPair::{ a, b, diff: diff + combo, combo, }
  if !pairs.is_empty() && pairs[0].less(pair) {
    if pairs.length() < limit {
      pairs.push(pairs[0])
    }
    pairs[0] = pair
  } else if pairs.length() < limit {
    pairs.push(pair)
  }
}

///|
fn hq_combine(
  out : Array[HqHistogram],
  tmp : HqHistogram,
  sizes : FixedArray[Int32],
  symbols : MutArrayView[Int32],
  clusters : Array[Int32],
  max_clusters : Int32,
  max_pairs : Int32,
  memory? : HqMemory,
) -> Unit {
  let mark = hq_memory_mark(memory)
  defer hq_memory_restore(memory, mark)
  let pairs : Array[HqPair] = Array(capacity=max_pairs + 1)
  hq_memory_add(memory, 32L * pairs.capacity().to_int64())
  for i in 0..<clusters.length() {
    for j in (i + 1)..<clusters.length() {
      hq_compare(
        out,
        tmp,
        sizes,
        clusters[i],
        clusters[j],
        max_pairs,
        pairs,
        memory?,
      )
    }
  }
  let mut threshold = 0.0
  let mut minimum = 1
  while clusters.length() > minimum {
    if pairs[0].diff >= threshold {
      threshold = 1.0e99
      minimum = max_clusters
      continue
    }
    let best = pairs[0]
    out[best.a].merge(out[best.b])
    out[best.a].cost = best.combo
    sizes[best.a] += sizes[best.b]
    for i in 0..<symbols.length() {
      if symbols[i] == best.b {
        symbols[i] = best.a
      }
    }
    let mut at = 0
    while clusters[at] != best.b {
      at += 1
    }
    clusters.remove(at) |> ignore
    let mut keep = 0
    for i in 0..<pairs.length() {
      let p = pairs[i]
      if p.a == best.a || p.b == best.a || p.a == best.b || p.b == best.b {
        continue
      }
      if pairs[0].less(p) {
        let front = pairs[0]
        pairs[0] = p
        pairs[keep] = front
      } else {
        pairs[keep] = p
      }
      keep += 1
    }
    pairs.truncate(keep)
    for c in clusters {
      hq_compare(out, tmp, sizes, best.a, c, max_pairs, pairs, memory?)
    }
  }
}

///|
fn hq_hist_distance(
  hist : HqHistogram,
  candidate : HqHistogram,
  tmp : HqHistogram,
  memory? : HqMemory,
) -> Double {
  if hist.total == 0 {
    return 0.0
  }
  tmp.assign(hist)
  tmp.merge(candidate)
  tmp.population(memory?) - candidate.cost
}

///|
fn hq_cluster(
  input : Array[HqHistogram],
  memory? : HqMemory,
) -> (Array[HqHistogram], FixedArray[Int32]) {
  let mark = hq_memory_mark(memory)
  defer hq_memory_restore(memory, mark)
  let n = input.length()
  let alphabet = input[0].data.length()
  let out = input.map(h => {
    let v = HqHistogram::new(alphabet)
    v.assign(h)
    v.cost = h.population(memory?)
    v
  })
  let sizes = FixedArray::make(n, 1)
  let symbols = FixedArray::makei(n, i => i)
  let clusters : Array[Int32] = []
  let tmp = HqHistogram::new(alphabet)
  hq_memory_add(
    memory,
    hq_histograms_memory(out) +
    tmp.memory_usage() +
    4L * (sizes.length() + symbols.length()).to_int64(),
  )
  for i = 0; i < n; i = i + 64 {
    let count = (n - i).min(64)
    let batch = Array::makei(count, j => i + j)
    let batch_mark = hq_memory_mark(memory)
    hq_memory_add(memory, 4L * batch.capacity().to_int64())
    hq_combine(
      out,
      tmp,
      sizes,
      symbols.mut_view(start=i, end=i + count),
      batch,
      256,
      2048,
      memory?,
    )
    let old_capacity = clusters.capacity()
    for c in batch {
      clusters.push(c)
    }
    hq_memory_restore(memory, batch_mark)
    hq_memory_add(memory, 4L * (clusters.capacity() - old_capacity).to_int64())
  }
  let max_pairs = hq_max_pairs(clusters.length())
  hq_combine(
    out,
    tmp,
    sizes,
    symbols.mut_view(),
    clusters,
    256,
    max_pairs,
    memory?,
  )
  for i in 0..<n {
    let mut best = if i == 0 { symbols[0] } else { symbols[i - 1] }
    let mut cost = hq_hist_distance(input[i], out[best], tmp, memory?)
    for c in clusters {
      let value = hq_hist_distance(input[i], out[c], tmp, memory?)
      if value < cost {
        cost = value
        best = c
      }
    }
    symbols[i] = best
  }
  for c in clusters {
    out[c].clear()
  }
  for i in 0..<n {
    out[symbols[i]].merge(input[i])
  }
  let index = FixedArray::make(n, -1)
  hq_memory_add(memory, 4L * index.length().to_int64())
  let result : Array[HqHistogram] = []
  for i in 0..<n {
    let old = symbols[i]
    if index[old] < 0 {
      index[old] = result.length()
      result.push(out[old])
    }
    symbols[i] = index[old]
  }
  // The result aliases out's histogram objects: charge only its slots here.
  hq_memory_add(memory, 8L * result.capacity().to_int64())
  (result, symbols)
}
