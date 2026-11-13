// Encoding with FSE (RFC 8878 section 4.1): the encoder's table, and a
// stream's states. The encoder goes through the symbols in reverse, so that
// the decoder, which reads the stream backward, meets them in order.
//
// The table is the reference encoder's (`FSE_buildCTable` and
// `FSE_encodeSymbol` in fse_compress.c and fse.h). An encoder's state is a
// decoder's state plus the table size. The decoder, at state `t` of symbol
// `s` whose probability is `p`, reads `nbits` bits to go to a state in
// `[base, base + 2^nbits)`, where its states of `s`, in order, stand for
// `p, p + 1, .., 2p - 1` and the one standing for `x` has
// `nbits = log - highbit(x)`, `base = (x << nbits) - size`. So the encoder,
// to emit `s` from state `v` (a decoder's next state plus `size`), writes
// the `nbits` low bits of `v` for the `nbits` that brings `v >> nbits` into
// `[p, 2p)`, and goes to the state of `s` that stands for `v >> nbits`.
// `nbits` is one of two values for each symbol, found with one addition
// and shift (`delta_bits`); the state, with one addition (`delta_state`)
// into the list of states grouped by symbol.

///|
/// An encoding table for distributions over up to `1 << max_log` states
/// and `max_symbols` symbols.
pub struct CTable {
  // The encoder's states (`size + t`), grouped by symbol, each symbol's
  // in increasing order.
  priv states : FixedArray[Int32]
  // Per symbol: `(nbits << 16) - (p << nbits)` for the larger `nbits`, so
  // that `(v + delta_bits) >> 16` is the number of bits to write from `v`.
  priv delta_bits : FixedArray[Int32]
  // Per symbol: where its states start in `states`, less `p`.
  priv delta_state : FixedArray[Int32]
  // Scratch: the symbol of each decoder state, and where each symbol's
  // next state goes in `states`.
  priv symbols : FixedArray[Byte]
  priv next : FixedArray[Int32]
  priv mut log : Int32
}

///|
/// A table with room for `1 << max_log` states and `max_symbols` symbols.
pub fn CTable::CTable(max_log~ : Int32, max_symbols~ : Int32) -> CTable {
  let size = 1 << max_log
  {
    states: FixedArray::make(size, 0),
    delta_bits: FixedArray::make(max_symbols, 0),
    delta_state: FixedArray::make(max_symbols, 0),
    symbols: FixedArray::make(size, b'\x00'),
    next: FixedArray::make(max_symbols, 0),
    log: 0,
  }
}

///|
/// The table's accuracy log, since it was last built.
pub fn CTable::log(self : CTable) -> Int32 {
  self.log
}

///|
/// The bytes the table holds.
pub fn CTable::memory_usage(self : CTable) -> Int32 {
  4 *
  (
    self.states.length() +
    self.delta_bits.length() +
    self.delta_state.length() +
    self.next.length()
  ) +
  self.symbols.length()
}

///|
/// Builds the table of `norm[0:count]`, a distribution over `1 << log`
/// states in which -1 stands for "less than 1", as `normalize` gives: the
/// symbols take the states that the decoder's table of the same
/// distribution gives them.
pub fn CTable::build(
  self : CTable,
  norm : FixedArray[Int32],
  count : Int32,
  log : Int32,
) -> Unit {
  let size = 1 << log
  self.log = log
  // A normalized distribution fills the table exactly (PROOFS.md), so the
  // spread always ends where it began.
  spread(norm, count, log, self.symbols) |> ignore
  let mut start = 0
  for s in 0..<count {
    let p = if norm[s] == -1 { 1 } else { norm[s] }
    self.next[s] = start
    if p == 1 {
      // Every state of the symbol reads all `log` bits.
      self.delta_bits[s] = (log << 16) - size
      self.delta_state[s] = start - 1
    } else if p > 1 {
      let max_bits = log - high_bit(p - 1)
      self.delta_bits[s] = (max_bits << 16) - (p << max_bits)
      self.delta_state[s] = start - p
    } else {
      self.delta_bits[s] = 0
      self.delta_state[s] = 0
    }
    start += p
  }
  for t in 0..<size {
    let s = self.symbols[t].to_int()
    self.states[self.next[s]] = size + t
    self.next[s] += 1
  }
}

///|
/// The state to start a stream with, whose symbol is the last `symbol` the
/// stream holds: no bits are written for it. It is the symbol's first state,
/// whose transition reads the most bits, at least 1 unless the symbol has
/// every state: a stream whose end the decoder detects by running out of
/// bits (Huffman weights) relies on that.
pub fn CTable::start(self : CTable, symbol : Int32) -> Int32 {
  let nbits = (self.delta_bits[symbol] + (1 << 15)) >> 16
  let value = (nbits << 16) - self.delta_bits[symbol]
  self.states[(value >> nbits) + self.delta_state[symbol]]
}

///|
/// Emits `symbol` before those of `state`: writes the bits that take the
/// decoder from the state of `symbol` to `state`, and returns the state of
/// `symbol`.
pub fn CTable::encode(
  self : CTable,
  out : @bits.BitPacker,
  state : Int32,
  symbol : Int32,
) -> Int32 {
  let nbits = (state + self.delta_bits[symbol]) >> 16
  out.write(nbits, state & ((1 << nbits) - 1))
  self.states[(state >> nbits) + self.delta_state[symbol]]
}

///|
/// Writes `state` as the decoder's initial state: `log` bits, the last
/// thing written for the stream, so the first the decoder reads.
pub fn CTable::finish(
  self : CTable,
  out : @bits.BitPacker,
  state : Int32,
) -> Unit {
  out.write(self.log, state - (1 << self.log))
}
