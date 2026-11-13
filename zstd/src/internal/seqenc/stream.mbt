///|
/// An independently selected sequence stream. The previous distribution
/// is committed only after the enclosing compressed block is accepted.
struct Stream {
  counts : FixedArray[Int32]
  norm : FixedArray[Int32]
  previous : FixedArray[Int32]
  defaults : FixedArray[Int32]
  max_log : Int32
  default_log : Int32
  table : @fse.CTable
  scratch : @bits.BitPacker
  mut previous_log : Int32
  mut log : Int32
  mut mode : Int32
  mut symbol : Int32
  mut alphabet : Int32
}

///|
fn Stream::new(
  defaults : FixedArray[Int32],
  symbols : Int32,
  max_log : Int32,
  default_log : Int32,
) -> Stream {
  {
    counts: FixedArray::make(symbols, 0),
    norm: FixedArray::make(symbols, 0),
    previous: FixedArray::make(symbols, 0),
    defaults,
    max_log,
    default_log,
    table: @fse.CTable(max_log~, max_symbols=symbols),
    scratch: @bits.BitPacker(),
    previous_log: -1,
    log: 0,
    mode: 0,
    symbol: 0,
    alphabet: 0,
  }
}

///|
// Conservative integer Shannon cost, in bits. A missing symbol makes the
// table ineligible. Headers and initial states count; rounding up favours
// simpler tables rather than overfitting tiny histograms.
fn Stream::cost(
  self : Stream,
  norm : FixedArray[Int32],
  log : Int32,
  header : Int32,
) -> Int32 {
  let mut cost = header * 8 + log
  for s in 0..<self.counts.length() {
    let n = self.counts[s]
    if n == 0 {
      continue
    }
    if s >= norm.length() || norm[s] == 0 {
      return 1 << 28
    }
    let p = norm[s].abs()
    // ceil(log2(size/p)), with an eighth-bit interpolation between powers
    // of two. Arithmetic remains below 2^27 for one block.
    let high = 31 - p.clz()
    let fraction = ((p - (1 << high)) * 8) >> high
    cost += (n * ((log - high) * 8 - fraction) + 7) / 8
  }
  cost
}

///|
fn Stream::select(self : Stream, count : Int32) -> Unit {
  let mut distinct = 0
  let mut alphabet = 0
  for s in 0..<self.counts.length() {
    if self.counts[s] > 0 {
      distinct += 1
      alphabet = s + 1
    }
  }
  self.alphabet = alphabet
  self.symbol = alphabet - 1
  self.norm.fill(0)
  // Single-symbol FSE_Compressed is forbidden by RFC 8878. Repeat of an
  // identical RLE table saves its symbol byte and is also legal.
  if distinct == 1 {
    self.mode = if self.previous_log == 0 && self.previous[self.symbol] == 1 {
      3
    } else {
      1
    }
    self.log = 0
    self.norm[self.symbol] = 1
  } else {
    self.mode = 0
    self.log = self.default_log
    let mut best = self.cost(self.defaults, self.default_log, 0)
    if self.previous_log >= 0 {
      let cost = self.cost(self.previous, self.previous_log, 0)
      if cost <= best {
        best = cost
        self.mode = 3
        self.log = self.previous_log
      }
    }
    let log = @fse.accuracy_log(count, alphabet, self.max_log)
    @fse.normalize(self.counts, alphabet, count, log, true, self.norm)
    self.scratch.reset()
    @fse.write_description(self.scratch, self.norm, alphabet, log)
    let cost = self.cost(self.norm, log, self.scratch.pending())
    if cost < best {
      self.mode = 2
      self.log = log
    }
    if self.mode != 2 {
      let source = if self.mode == 3 { self.previous } else { self.defaults }
      self.norm.fill(0)
      for s in 0..<source.length() {
        self.norm[s] = source[s]
      }
    }
  }
  self.table.build(self.norm, self.norm.length(), self.log)
}

///|
fn Stream::describe(self : Stream, out : @bits.BitPacker) -> Unit {
  if self.mode == 1 {
    out.write(8, self.symbol)
  } else if self.mode == 2 {
    @fse.write_description(out, self.norm, self.alphabet, self.log)
  }
}

///|
fn Stream::commit(self : Stream) -> Unit {
  for s in 0..<self.norm.length() {
    self.previous[s] = self.norm[s]
  }
  self.previous_log = self.log
}

///|
fn Stream::memory_usage(self : Stream) -> Int32 {
  12 * self.norm.length() + self.table.memory_usage() + self.scratch.capacity()
}
