// Port of google/brotli v1.2.1 c/enc/metablock{,_inc.h}.c, encode.c,
// and bit_cost.c. Copyright 2013, 2015 Google Inc.; MIT, LICENSE-encoder.

///|
fn ref_log(n : Int32) -> Double {
  if n < 256 {
    ref_small_log(n)
  } else {
    @math.log2(n.to_double())
  }
}

///|
fn ref_entropy(hist : FixedArray[Int32], minimum~ : Bool = true) -> Double {
  let mut total = 0
  let mut cost = 0.0
  for n in hist {
    total += n
    cost -= n.to_double() * ref_log(n)
  }
  if total > 0 {
    cost += total.to_double() * ref_log(total)
  }
  if minimum {
    cost.max(total.to_double())
  } else {
    cost
  }
}

///|
priv struct RefSplit {
  alphabet : Int32
  contexts : Int32
  min_size : Int32
  threshold : Double
  hist : Array[FixedArray[Int32]]
  types : Array[Int32]
  lengths : Array[Int32]
  mut current : FixedArray[Int32]
  mut size : Int32
  mut target : Int32
  mut merges : Int32
  mut last : Int32
  mut second : Int32
  mut last_entropy : FixedArray[Double]
  mut second_entropy : FixedArray[Double]
}

///|
fn RefSplit::new(
  alphabet : Int32,
  contexts : Int32,
  min_size : Int32,
  threshold : Double,
) -> RefSplit {
  {
    alphabet,
    contexts,
    min_size,
    threshold,
    hist: Array(),
    types: Array(),
    lengths: Array(),
    current: FixedArray::make(alphabet * contexts, 0),
    size: 0,
    target: min_size,
    merges: 0,
    last: 0,
    second: 0,
    last_entropy: FixedArray::make(contexts, 0.0),
    second_entropy: FixedArray::make(contexts, 0.0),
  }
}

///|
fn RefSplit::entropies(
  self : RefSplit,
  hist : FixedArray[Int32],
) -> FixedArray[Double] {
  FixedArray::makei(self.contexts, c => {
    ref_entropy(
      FixedArray::makei(self.alphabet, i => hist[c * self.alphabet + i]),
    )
  })
}

///|
fn RefSplit::finish(self : RefSplit) -> Unit {
  let size = self.size.max(self.min_size)
  let entropy = self.entropies(self.current)
  if self.hist.is_empty() {
    self.hist.push(self.current)
    self.types.push(0)
    self.lengths.push(size)
    self.last_entropy = entropy
    self.second_entropy = entropy.copy()
  } else {
    let combined = [self.last, self.second].map(which => {
      FixedArray::makei(self.current.length(), i => {
        self.current[i] + self.hist[which][i]
      })
    })
    let costs = combined.map(hist => self.entropies(hist))
    let diff = FixedArray::make(2, 0.0)
    for c in 0..<self.contexts {
      diff[0] += costs[0][c] - entropy[c] - self.last_entropy[c]
      diff[1] += costs[1][c] - entropy[c] - self.second_entropy[c]
    }
    if self.hist.length() < 256 / self.contexts &&
      diff[0] > self.threshold &&
      diff[1] > self.threshold {
      self.types.push(self.hist.length())
      self.lengths.push(size)
      self.second = self.last
      self.last = self.hist.length()
      self.hist.push(self.current)
      self.second_entropy = self.last_entropy
      self.last_entropy = entropy
      self.merges = 0
      self.target = self.min_size
    } else if diff[1] < diff[0] - 20.0 {
      self.types.push(self.types[self.types.length() - 2])
      self.lengths.push(size)
      let t = self.last
      self.last = self.second
      self.second = t
      self.hist[self.last] = combined[1]
      self.second_entropy = self.last_entropy
      self.last_entropy = costs[1]
      self.merges = 0
      self.target = self.min_size
    } else {
      self.lengths[self.lengths.length() - 1] += size
      self.hist[self.last] = combined[0]
      self.last_entropy = costs[0]
      if self.hist.length() == 1 {
        self.second_entropy = costs[0].copy()
      }
      self.merges += 1
      if self.merges > 1 {
        self.target += self.min_size
      }
    }
  }
  self.current = FixedArray::make(self.alphabet * self.contexts, 0)
  self.size = 0
}

///|
fn RefSplit::add(self : RefSplit, symbol : Int32, context~ : Int32 = 0) -> Unit {
  self.current[context * self.alphabet + symbol] += 1
  self.size += 1
  if self.size == self.target {
    self.finish()
  }
}

///|
fn ref_complex_map() -> FixedArray[Int32] {
  [
    11, 11, 12, 12, 0, 0, 0, 0, 1, 1, 9, 9, 2, 2, 2, 2, 1, 1, 1, 1, 8, 3, 3, 3, 1,
    1, 1, 1, 2, 2, 2, 2, 8, 4, 4, 4, 8, 7, 4, 4, 8, 0, 0, 0, 3, 3, 3, 3, 5, 5, 10,
    5, 5, 5, 10, 5, 6, 6, 6, 6, 6, 6, 6, 6,
  ]
}

///|
fn ref_context_map(
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
  quality : Int32,
  hint : Int64,
) -> (Int32, FixedArray[Int32]) {
  let simple = FixedArray::makei(64, i => if i == 2 || i == 3 { 1 } else { 0 })
  if end - start < 64 {
    return (1, simple)
  }
  if hint >= 1048576L {
    let complex_map = ref_complex_map()
    let all = FixedArray::make(32, 0)
    let hist = FixedArray::make(13 * 32, 0)
    let mut total = 0
    for at = start; at + 64 <= end; at = at + 4096 {
      let mut p2 = data[at].to_int()
      let mut p1 = data[at + 1].to_int()
      for p in (at + 2)..<(at + 64) {
        let b = data[p].to_int()
        let ctx = complex_map[literal_context(2, p1, p2)]
        all[b >> 3] += 1
        hist[32 * ctx + (b >> 3)] += 1
        total += 1
        p2 = p1
        p1 = b
      }
    }
    let no_context = ref_entropy(all, minimum=false) / total.to_double()
    let mut with_context = 0.0
    for c in 0..<13 {
      with_context += ref_entropy(
        FixedArray::makei(32, i => hist[c * 32 + i]),
        minimum=false,
      )
    }
    with_context /= total.to_double()
    if with_context <= 3.0 && no_context - with_context >= 0.2 {
      return (13, complex_map)
    }
  }
  let bigram = FixedArray::make(9, 0)
  let lut : FixedArray[Int32] = [0, 0, 1, 2]
  for at = start; at + 64 <= end; at = at + 4096 {
    let mut prev = lut[data[at].to_int() >> 6]
    for p in (at + 1)..<(at + 64) {
      let next = lut[data[p].to_int() >> 6]
      bigram[3 * prev + next] += 1
      prev = next
    }
  }
  let mono = FixedArray::make(3, 0)
  let two = FixedArray::make(6, 0)
  let mut total = 0
  for i in 0..<9 {
    mono[i % 3] += bigram[i]
    two[i % 6] += bigram[i]
    total += bigram[i]
  }
  let scale = 1.0 / total.to_double()
  let e1 = ref_entropy(mono, minimum=false) * scale
  let e2 = (
      ref_entropy(FixedArray::makei(3, i => two[i]), minimum=false) +
      ref_entropy(FixedArray::makei(3, i => two[i + 3]), minimum=false)
    ) *
    scale
  let mut e3 = 0.0
  for c in 0..<3 {
    e3 += ref_entropy(
      FixedArray::makei(3, i => bigram[3 * c + i]),
      minimum=false,
    )
  }
  e3 *= scale
  if quality < 7 {
    e3 = e1 * 10.0
  }
  if e1 - e2 < 0.2 && e1 - e3 < 0.2 {
    (1, simple)
  } else if e2 - e3 < 0.02 {
    (2, simple)
  } else {
    (
      3,
      FixedArray::makei(64, i => if i < 2 { 1 } else if i < 4 { 2 } else { 0 }),
    )
  }
}
