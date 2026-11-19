///|
/// The frame's sequence tables and repeat offsets, with speculative block
/// selection followed by explicit commit.
pub struct Writer {
  priv ll : Stream
  priv ml : Stream
  priv of : Stream
  repeats : Repeats
}

///|
/// A frame with no previous sequence tables.
pub fn Writer::Writer() -> Writer {
  {
    ll: Stream::new(ll_default, 36, 9, 6),
    ml: Stream::new(ml_default, 53, 9, 6),
    of: Stream::new(of_default, 32, 8, 5),
    repeats: Repeats(),
  }
}

///|
/// Drops every table and repeat offset inherited from the previous frame.
pub fn Writer::reset(self : Writer) -> Unit {
  self.ll.previous_log = -1
  self.ml.previous_log = -1
  self.of.previous_log = -1
  self.repeats.reset()
}

///|
/// Starts the frame from a formatted dictionary's sequence tables, given by
/// their normalized counts and accuracy logs, as if a block before it had
/// used them: a block may repeat them (mode 3).
pub fn Writer::seed(
  self : Writer,
  ll : FixedArray[Int32],
  ll_log : Int32,
  ml : FixedArray[Int32],
  ml_log : Int32,
  of : FixedArray[Int32],
  of_log : Int32,
) -> Unit {
  self.ll.seed(ll, ll_log)
  self.ml.seed(ml, ml_log)
  self.of.seed(of, of_log)
}

///|
/// The modes chosen by the latest nonempty `write`, LL, OF, ML (0..3).
pub fn Writer::modes(self : Writer) -> (Int32, Int32, Int32) {
  (self.ll.mode, self.of.mode, self.ml.mode)
}

///|
/// Writes a complete sequence section at a byte boundary. States and
/// extras are emitted in the reverse of the decoder's read order:
/// LL/ML/OF transitions, then LL/ML/OF extras, finishing ML/OF/LL states.
/// The last sequence initializes the states and has no transitions.
pub fn Writer::write(
  self : Writer,
  out : @bits.BitPacker,
  block : Block,
) -> Unit {
  let n = block.count
  write_count(out, n)
  if n == 0 {
    return
  }
  let ll = block.ll
  let ml = block.ml
  let offsets = block.offsets
  let ll_counts = self.ll.counts
  let ml_counts = self.ml.counts
  let of_counts = self.of.counts
  ll_counts.fill(0)
  ml_counts.fill(0)
  of_counts.fill(0)
  for i in 0..<n {
    // Block::add has written the first n entries of all three arrays.
    let lc = ll_code(ll.unsafe_get(i))
    let mc = ml_code(ml.unsafe_get(i))
    let oc = offset_code(offsets.unsafe_get(i))
    // The counts arrays cover their respective alphabets: 36, 53, and
    // 32 codes. A positive OffsetValue has a highest bit in 0..31.
    ll_counts.unsafe_set(lc, ll_counts.unsafe_get(lc) + 1)
    ml_counts.unsafe_set(mc, ml_counts.unsafe_get(mc) + 1)
    of_counts.unsafe_set(oc, of_counts.unsafe_get(oc) + 1)
  }
  self.ll.select(n)
  self.of.select(n)
  self.ml.select(n)
  out.write(8, (self.ll.mode << 6) | (self.of.mode << 4) | (self.ml.mode << 2))
  self.ll.describe(out)
  self.of.describe(out)
  self.ml.describe(out)
  let lt = self.ll.table
  let mt = self.ml.table
  let ot = self.of.table
  let mut ls = lt.start(ll_code(ll[n - 1]))
  let mut ms = mt.start(ml_code(ml[n - 1]))
  let mut os = ot.start(offset_code(offsets[n - 1]))
  for i = n - 1; i >= 0; i = i - 1 {
    // i stays in 0..<n, the written prefix of each sequence array.
    let literal_len = ll.unsafe_get(i)
    let match_len = ml.unsafe_get(i)
    let offset = offsets.unsafe_get(i)
    let lc = ll_code(literal_len)
    let mc = ml_code(match_len)
    let oc = offset_code(offset)
    let extra = offset_extra(offset, oc)
    if i < n - 1 {
      os = ot.encode(out, os, oc)
      ms = mt.encode(out, ms, mc)
      ls = lt.encode(out, ls, lc)
    }
    // The extra-bit and base tables cover every LL and ML code.
    out.write(ll_bits.unsafe_get(lc), literal_len - ll_base.unsafe_get(lc))
    out.write(ml_bits.unsafe_get(mc), match_len - ml_base.unsafe_get(mc))
    // At most 31 bits in one call. BitPacker splits internally on JS
    // when these and a partial byte would exceed its 32-bit accumulator.
    out.write(oc, extra.reinterpret_as_int())
  }
  mt.finish(out, ms)
  ot.finish(out, os)
  lt.finish(out, ls)
  out.write_end_mark()
}

///|
/// Adopts the candidate only after its compressed block was selected.
pub fn Writer::commit(self : Writer, block : Block) -> Unit {
  if block.count > 0 {
    self.ll.commit()
    self.ml.commit()
    self.of.commit()
    self.repeats.copy_from(block.repeats)
  }
}

///|
/// Retained table and scratch bytes, including repeat history.
pub fn Writer::memory_usage(self : Writer) -> Int32 {
  self.ll.memory_usage() + self.ml.memory_usage() + self.of.memory_usage() + 12
}
