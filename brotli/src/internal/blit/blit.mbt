// Generated from parts/blit/blit.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// On native, Wasm and Wasm GC a long copy is one block move, which decoded png's
// benchmark image 10 to 15% faster than a byte loop on native and Wasm. On
// JS, core's block copy is a loop that checks every index and runs
// backwards; a forward loop without the checks decoded it 10% faster
// (bench/, 2026-10-22).

///|
/// Copies `src[at:at + n]` to `dst[to:to + n]`. The caller has checked that
/// both ranges are within their arrays and do not overlap; `dst` may be
/// `src` (a match in a window whose distance is at least its length).
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
/// both ranges are within their arrays and do not overlap; `dst` may be
/// `src` (a match in a window whose distance is at least its length).
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

///|
/// Copies `n` bytes of `ring` from `from` to `to`, `from < to`, front to
/// back, so that a byte written may be read again: an LZ77 match shorter
/// than its distance repeats, as the decoders of zstd, Brotli and DEFLATE
/// need. Eight bytes at a time when `to - from` is 8 or more (each eight
/// read lie before the eight written), then byte by byte; nothing past
/// `to + n` is written, where a window may hold history. The caller has
/// checked that both ranges are within `ring`.
#cfg(any(target="native", target="wasm"))
pub fn forward(
  ring : FixedArray[Byte],
  to : Int32,
  from : Int32,
  n : Int32,
) -> Unit {
  let mut i = 0
  if to - from >= 8 {
    let bytes = ring.unsafe_reinterpret_as_bytes()
    while i + 8 <= n {
      ring.unsafe_write_uint64_le(to + i, bytes.unsafe_read_uint64_le(from + i))
      i += 8
    }
  }
  while i < n {
    ring.unsafe_set(to + i, ring.unsafe_get(from + i))
    i += 1
  }
}

///|
/// `forward` byte by byte: JS and Wasm GC have no eight-byte loads.
#cfg(not(any(target="native", target="wasm")))
pub fn forward(
  ring : FixedArray[Byte],
  to : Int32,
  from : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    ring.unsafe_set(to + i, ring.unsafe_get(from + i))
  }
}

///|
/// Moves `buf[at:at + n]` down to `buf[to:to + n]`, `to <= at`: the ranges
/// may overlap, as when a window slides. The caller has checked that both
/// are within `buf`.
#cfg(not(target="js"))
pub fn move_down(
  buf : FixedArray[Byte],
  to : Int32,
  at : Int32,
  n : Int32,
) -> Unit {
  // The caller bounds both ranges. to <= at makes forward overlap safe.
  if n < 16 {
    for i in 0..<n {
      buf.unsafe_set(to + i, buf.unsafe_get(at + i))
    }
  } else {
    FixedArray::unsafe_blit(buf, to, buf, at, n)
  }
}

///|
/// Moves `buf[at:at + n]` down to `buf[to:to + n]`, `to <= at`: front to
/// back, so that each byte is read before it is written over.
#cfg(target="js")
pub fn move_down(
  buf : FixedArray[Byte],
  to : Int32,
  at : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    buf.unsafe_set(to + i, buf.unsafe_get(at + i))
  }
}

///|
/// Copies all of `src` to `dst[to:to + src.length()]`. The caller has
/// checked that the range is within `dst`, and that `src` does not view
/// `dst`.
#cfg(not(target="js"))
pub fn from_view(dst : FixedArray[Byte], to : Int32, src : BytesView) -> Unit {
  let n = src.length()
  if n < 16 {
    // i is within src, and the caller bounds the destination range.
    for i in 0..<n {
      dst.unsafe_set(to + i, src.unsafe_get(i))
    }
  } else {
    dst.blit_from_bytesview(to, src)
  }
}

///|
/// Copies all of `src` to `dst[to:to + src.length()]`, as above.
#cfg(target="js")
pub fn from_view(dst : FixedArray[Byte], to : Int32, src : BytesView) -> Unit {
  for i in 0..<src.length() {
    dst.unsafe_set(to + i, src.unsafe_get(i))
  }
}
