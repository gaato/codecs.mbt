// Helpers for the tests of the encoder's entropy coders, which check them
// against the decoder's readers.

///|
/// Everything `out` holds, at a byte boundary.
fn packed(out : @bits.BitPacker) -> FixedArray[Byte] {
  let data = FixedArray::make(out.pending(), b'\x00')
  out.drain_into(data, 0) |> ignore
  data
}

///|
/// The counts of `symbols`, over `alphabet` symbols.
fn histogram(symbols : Array[Int32], alphabet : Int32) -> FixedArray[Int32] {
  let counts = FixedArray::make(alphabet, 0)
  for s in symbols {
    counts[s] += 1
  }
  counts
}
