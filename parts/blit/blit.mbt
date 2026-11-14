// On native, Wasm and Wasm GC a copy is one block move, which decoded png's
// benchmark image 10 to 15% faster than a byte loop on native and Wasm. On
// JS, core's block copy is a loop that checks every index and runs
// backwards; a forward loop without the checks decoded it 10% faster
// (bench/, 2026-10-22).

///|
/// Copies `src[at:at + n]` to `dst[to:to + n]`. The caller has checked that
/// both ranges are within their arrays, and `dst` is not `src`.
#cfg(not(target="js"))
pub fn bytes(
  dst : FixedArray[Byte],
  to : Int32,
  src : FixedArray[Byte],
  at : Int32,
  n : Int32,
) -> Unit {
  FixedArray::unsafe_blit(dst, to, src, at, n)
}

///|
/// Copies `src[at:at + n]` to `dst[to:to + n]`. The caller has checked that
/// both ranges are within their arrays, and `dst` is not `src`.
#cfg(target="js")
pub fn bytes(
  dst : FixedArray[Byte],
  to : Int32,
  src : FixedArray[Byte],
  at : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    dst.unsafe_set(to + i, src.unsafe_get(at + i))
  }
}

///|
/// Copies `src[at:at + n]` to `dst[to:to + n]`. The caller has checked that
/// both ranges are within their arrays, and `dst` does not view `src`.
/// Short copies take a loop: the block move costs a slice and a call, which
/// made decoding into a one-byte buffer 15 to 25% slower than the loop.
#cfg(not(target="js"))
pub fn into_view(
  dst : MutArrayView[Byte],
  to : Int32,
  src : FixedArray[Byte],
  at : Int32,
  n : Int32,
) -> Unit {
  if n < 16 {
    for i in 0..<n {
      dst.unsafe_set(to + i, src.unsafe_get(at + i))
    }
  } else {
    dst.blit_from_array(src[at:at + n], dst_offset=to)
  }
}

///|
/// Copies `src[at:at + n]` to `dst[to:to + n]`. The caller has checked that
/// both ranges are within their arrays, and `dst` does not view `src`.
#cfg(target="js")
pub fn into_view(
  dst : MutArrayView[Byte],
  to : Int32,
  src : FixedArray[Byte],
  at : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    dst.unsafe_set(to + i, src.unsafe_get(at + i))
  }
}
