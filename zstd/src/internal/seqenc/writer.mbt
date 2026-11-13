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
  self.ll.counts.fill(0)
  self.ml.counts.fill(0)
  self.of.counts.fill(0)
  for i in 0..<n {
    self.ll.counts[ll_code(block.ll[i])] += 1
    self.ml.counts[ml_code(block.ml[i])] += 1
    self.of.counts[offset_code(block.offsets[i])] += 1
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
  let mut ls = lt.start(ll_code(block.ll[n - 1]))
  let mut ms = mt.start(ml_code(block.ml[n - 1]))
  let mut os = ot.start(offset_code(block.offsets[n - 1]))
  for i = n - 1; i >= 0; i = i - 1 {
    let lc = ll_code(block.ll[i])
    let mc = ml_code(block.ml[i])
    let oc = offset_code(block.offsets[i])
    let extra = offset_extra(block.offsets[i], oc)
    if i < n - 1 {
      os = ot.encode(out, os, oc)
      ms = mt.encode(out, ms, mc)
      ls = lt.encode(out, ls, lc)
    }
    out.write(ll_bits[lc], block.ll[i] - ll_base[lc])
    out.write(ml_bits[mc], block.ml[i] - ml_base[mc])
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
