// FSE decoding tables (RFC 8878 section 4.1): reading a table description
// and building the table from its normalized distribution.

///|
/// An FSE decoding table of `1 << log` states, at most `1 << 9`. Each state
/// gives a symbol and how to reach the next state: `base` plus `nbits` bits.
priv struct Fse {
  symbol : FixedArray[Byte]
  nbits : FixedArray[Byte]
  base : FixedArray[UInt16]
  mut log : Int32
}

///|
fn Fse::new(max_log : Int32) -> Fse {
  let size = 1 << max_log
  {
    symbol: FixedArray::make(size, b'\x00'),
    nbits: FixedArray::make(size, b'\x00'),
    base: FixedArray::make(size, 0),
    log: 0,
  }
}

///|
/// The table that always gives `symbol` and reads no bits (`RLE_Mode`).
fn Fse::set_rle(self : Fse, symbol : Byte) -> Unit {
  self.log = 0
  self.symbol[0] = symbol
  self.nbits[0] = b'\x00'
  self.base[0] = 0
}

///|
/// The symbol of `state`.
fn Fse::symbol_of(self : Fse, state : Int32) -> Int32 {
  self.symbol[state].to_int()
}

///|
/// The state after `state`, reading its bits from `bits`.
fn Fse::next(self : Fse, state : Int32, bits : BackwardBits) -> Int32 {
  self.base[state].to_int() + bits.read(self.nbits[state].to_int())
}

///|
/// Scratch for building tables: a distribution and the next state of each
/// symbol.
priv struct FseScratch {
  probs : FixedArray[Int32]
  next : FixedArray[Int32]
}

///|
fn FseScratch::new() -> FseScratch {
  { probs: FixedArray::make(256, 0), next: FixedArray::make(256, 0), }
}

///|
/// Builds `self` from `probs[0:count]`, a distribution summing to
/// `1 << log` in which -1 stands for "less than 1" (RFC 8878 section
/// 4.1.1). False when the rows do not come out exactly filled, which only a
/// corrupt description can cause.
fn Fse::build(
  self : Fse,
  probs : FixedArray[Int32],
  count : Int32,
  log : Int32,
  next : FixedArray[Int32],
) -> Bool {
  let size = 1 << log
  self.log = log
  let mut high = size - 1
  for s in 0..<count {
    if probs[s] == -1 {
      self.symbol[high] = s.to_byte()
      high -= 1
      next[s] = 1
    } else {
      next[s] = probs[s]
    }
  }
  let step = (size >> 1) + (size >> 3) + 3
  let mask = size - 1
  let mut pos = 0
  for s in 0..<count {
    for _ in 0..<probs[s] {
      self.symbol[pos] = s.to_byte()
      pos = (pos + step) & mask
      while pos > high {
        pos = (pos + step) & mask
      }
    }
  }
  guard pos == 0 else { return false }
  for i in 0..<size {
    let s = self.symbol[i].to_int()
    let state = next[s]
    next[s] = state + 1
    let nbits = log - (31 - state.clz())
    self.nbits[i] = nbits.to_byte()
    self.base[i] = ((state << nbits) - size).to_uint16()
  }
  true
}

///|
/// Reads a table description from `data[start:end]` (RFC 8878 section
/// 4.1.1) and builds `self` from it. Symbols above `max_symbol` and accuracy
/// logs above `max_log` are refused. Returns the bytes the description used.
fn Fse::read(
  self : Fse,
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
  max_log : Int32,
  max_symbol : Int32,
  scratch : FseScratch,
) -> Int32 raise Stop {
  let bits = ForwardBits::new(data, start, end)
  let log = bits.read(4) + 5
  if log > max_log {
    raise corrupt("an FSE accuracy log above \{max_log}")
  }
  let probs = scratch.probs
  let mut remaining = 1 << log
  let mut count = 0
  while remaining > 0 {
    if count > max_symbol {
      raise corrupt("an FSE probability for a symbol out of range")
    }
    // Values 0..remaining + 1, in `width` bits or one fewer for the smaller
    // values.
    let width = 32 - (remaining + 1).clz()
    let low_mask = (1 << (width - 1)) - 1
    let threshold = (1 << width) - 1 - (remaining + 1)
    let mut value = bits.peek(width)
    if (value & low_mask) < threshold {
      value = value & low_mask
      bits.pos += width - 1
    } else {
      if value > low_mask {
        value -= threshold
      }
      bits.pos += width
    }
    if !bits.in_bounds() {
      raise corrupt("a table description runs past its section")
    }
    let prob = value - 1
    remaining -= if prob < 0 { 1 } else { prob }
    probs[count] = prob
    count += 1
    if prob == 0 {
      for ;; {
        let repeat = bits.read(2)
        if !bits.in_bounds() {
          raise corrupt("a table description runs past its section")
        }
        if count + repeat > max_symbol + 1 {
          raise corrupt("an FSE probability for a symbol out of range")
        }
        for _ in 0..<repeat {
          probs[count] = 0
          count += 1
        }
        if repeat < 3 {
          break
        }
      }
    }
  }
  // RFC 8878 asks for two symbols or more; the reference decoder also
  // takes a single symbol with every state (its transitions read no bits),
  // and so does this one.
  if !self.build(probs, count, log, scratch.next) {
    raise corrupt("an FSE distribution that does not fill its table")
  }
  bits.bytes_used()
}

///|
/// Builds a table from a fixed distribution, which fills it exactly.
fn Fse::predefined(probs : FixedArray[Int32], log : Int32) -> Fse {
  let table = Fse::new(log)
  table.build(probs, probs.length(), log, FixedArray::make(64, 0)) |> ignore
  table
}

///|
/// The default tables of RFC 8878 section 3.1.1.3.2.2.
let ll_predefined : Fse = Fse::predefined(ll_default, 6)

///|
let ml_predefined : Fse = Fse::predefined(ml_default, 6)

///|
let of_predefined : Fse = Fse::predefined(of_default, 5)
