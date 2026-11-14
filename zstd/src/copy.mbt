// Copies within the window, for sequence execution: the literals and
// matches of a block are mostly a few bytes long, where a call to memmove
// costs more than the copy.

///|
/// Copies `src[from:from + n]` to `dst[to:to + n]`, whose ranges the caller
/// has checked and which do not overlap.
fn copy_forward(
  dst : FixedArray[Byte],
  to : Int32,
  src : FixedArray[Byte],
  from : Int32,
  n : Int32,
) -> Unit {
  if n > 32 {
    @blit.bytes(dst, to, src, from, n)
  } else {
    copy_short(dst, to, src, from, n)
  }
}

///|
/// Copies `n` bytes from `src` to `dst` in `ring`, `src < dst`, going
/// forward so that a byte written may be read again: a match whose
/// distance `dst - src` is shorter than it. The caller has checked that
/// `dst + n` is within `ring`.
fn copy_overlapping(
  ring : FixedArray[Byte],
  dst : Int32,
  src : Int32,
  n : Int32,
) -> Unit {
  let dist = dst - src
  if dist >= 8 {
    // Each eight bytes read lie before the eight written.
    copy_short(ring, dst, ring, src, n)
  } else {
    for i in 0..<n {
      // src + i < dst + i < dst + n, within the ring.
      ring.unsafe_set(dst + i, ring.unsafe_get(src + i))
    }
  }
}

///|
/// Copies eight bytes at a time, front to back, then the rest byte by byte:
/// nothing past `to + n` is written.
#cfg(any(target="native", target="wasm"))
fn copy_short(
  dst : FixedArray[Byte],
  to : Int32,
  src : FixedArray[Byte],
  from : Int32,
  n : Int32,
) -> Unit {
  let s = src.unsafe_reinterpret_as_bytes()
  let mut i = 0
  // i + 8 <= n: the eight bytes are within both ranges.
  while i + 8 <= n {
    dst.unsafe_write_uint64_le(to + i, s.unsafe_read_uint64_le(from + i))
    i += 8
  }
  while i < n {
    dst.unsafe_set(to + i, src.unsafe_get(from + i))
    i += 1
  }
}

///|
/// Byte by byte, front to back: JS and Wasm GC have no eight-byte loads.
#cfg(not(any(target="native", target="wasm")))
fn copy_short(
  dst : FixedArray[Byte],
  to : Int32,
  src : FixedArray[Byte],
  from : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    dst.unsafe_set(to + i, src.unsafe_get(from + i))
  }
}

///|
/// Whether `wild_copy` and `wild_match` do eight-byte copies.
#cfg(any(target="native", target="wasm"))
let wide_copies : Bool = true

///|
#cfg(not(any(target="native", target="wasm")))
let wide_copies : Bool = false

///|
/// Copies `src[from:from + n]` to `dst[to:to + n]` eight bytes at a time,
/// writing up to 7 bytes past the end, and reading as many past
/// `from + n`: the caller has checked that both are within the arrays, and
/// that what it writes there may be lost.
#cfg(any(target="native", target="wasm"))
fn wild_copy(
  dst : FixedArray[Byte],
  to : Int32,
  src : FixedArray[Byte],
  from : Int32,
  n : Int32,
) -> Unit {
  let s = src.unsafe_reinterpret_as_bytes()
  let mut i = 0
  while i < n {
    dst.unsafe_write_uint64_le(to + i, s.unsafe_read_uint64_le(from + i))
    i += 8
  }
}

///|
#cfg(not(any(target="native", target="wasm")))
fn wild_copy(
  dst : FixedArray[Byte],
  to : Int32,
  src : FixedArray[Byte],
  from : Int32,
  n : Int32,
) -> Unit {
  copy_short(dst, to, src, from, n)
}

///|
/// A match of `n` bytes from `dist` back, written at `dst` in `ring` eight
/// bytes at a time and up to 7 bytes past its end (`wild_copy`'s terms).
/// Each eight bytes read lie before the eight written: at `dist` back when
/// it is 8 or more, and otherwise, once the first eight bytes are written
/// one by one, at the first multiple of `dist` that is 8 or more, where
/// the bytes repeat too.
#cfg(any(target="native", target="wasm"))
fn wild_match(
  ring : FixedArray[Byte],
  dst : Int32,
  dist : Int32,
  n : Int32,
) -> Unit {
  let bytes = ring.unsafe_reinterpret_as_bytes()
  let mut i = 0
  let mut back = dist
  if dist < 8 {
    for k in 0..<8 {
      ring.unsafe_set(dst + k, ring.unsafe_get(dst - dist + k))
    }
    i = 8
    back = (8 + dist - 1) / dist * dist
  }
  while i < n {
    ring.unsafe_write_uint64_le(
      dst + i,
      bytes.unsafe_read_uint64_le(dst + i - back),
    )
    i += 8
  }
}

///|
#cfg(not(any(target="native", target="wasm")))
fn wild_match(
  ring : FixedArray[Byte],
  dst : Int32,
  dist : Int32,
  n : Int32,
) -> Unit {
  if dist >= n {
    copy_forward(ring, dst, ring, dst - dist, n)
  } else {
    copy_overlapping(ring, dst, dst - dist, n)
  }
}
