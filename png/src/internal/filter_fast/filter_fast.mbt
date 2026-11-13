///|
/// Reverses filter type `kind` on the current row `cur` against the row
/// above, `prev`, as `@filter.unfilter` does, with the same arguments,
/// precondition and result: byte 0 of both rows is the filter type's place,
/// left alone, and nothing past `len + 1` or either row's end is read or
/// written.
///
/// The Up filter (type 2) runs sixteen bytes at a time with SIMD;
/// `@filter.unfilter` does the rest.
#cfg(any(target="native", target="wasm"))
pub fn unfilter(
  kind : Byte,
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  len : Int32,
  pixel : Int32,
) -> Bool where {
  proof_require: 1 <= pixel && pixel <= 8 && 0 <= len,
  proof_ensure: result => result == (kind.to_int() <= 4),
} {
  if kind == b'\x02' {
    up(cur, prev, bounded_end(len, cur.length(), prev.length()))
    true
  } else {
    @filter.unfilter(kind, cur, prev, len, pixel)
  }
}

///|
/// Reverses filter type `kind` on the current row `cur` against the row
/// above, `prev`: `@filter.unfilter` itself. On JS @v128 falls back to code
/// some 300 times slower, and Wasm GC cannot load sixteen bytes at once.
#cfg(not(any(target="native", target="wasm")))
pub fn unfilter(
  kind : Byte,
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  len : Int32,
  pixel : Int32,
) -> Bool where {
  proof_require: 1 <= pixel && pixel <= 8 && 0 <= len,
  proof_ensure: result => result == (kind.to_int() <= 4),
} {
  @filter.unfilter(kind, cur, prev, len, pixel)
}

///|
/// One past the last byte to reverse: `len + 1`, cut to both rows' lengths,
/// as `@filter.unfilter` computes it.
#cfg(any(target="native", target="wasm"))
fn bounded_end(
  len : Int32,
  cur : Int32,
  prev : Int32,
) -> Int32 where {
  proof_require: 0 <= cur && 0 <= prev,
  proof_ensure: result => result <= len + 1 && result <= cur && result <= prev,
} {
  let stop = if len + 1 < cur { len + 1 } else { cur }
  if stop < prev {
    stop
  } else {
    prev
  }
}

///|
/// Adds `prev` to `cur`, byte by byte from 1 to `stop`: sixteen bytes at a
/// time while sixteen remain (`i8x16_add`, one instruction on SSE2 and NEON),
/// then the rest through `@filter.up_from`.
///
/// The 226 Up rows of codec_bench's 512 x 384 RGB image, on an i5-10400F,
/// 2026-11-13: 18 us against 175 us a byte at a time on native, 26 us against
/// 271 us on Wasm, measured on their own.
#cfg(any(target="native", target="wasm"))
fn up(
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  stop : Int32,
) -> Unit where {
  proof_require: stop <= cur.length() && stop <= prev.length(),
  proof_ensure: true,
} {
  // Sixteen bytes from i fit while i < stop - 15. `stop` is negative when
  // `len + 1` wrapped, where `stop - 15` would wrap back to a large bound:
  // below 16 there is no sixteen-byte group at all.
  let groups_end = if stop < 16 { 0 } else { stop - 15 }
  for i = 1; i < groups_end; {
    store16(cur, i, add16(load16(cur, i), load16(prev, i)))
    continue i + 16
  } nobreak {
    @filter.up_from(cur, prev, i, stop)
  } where {
    proof_invariant: 1 <= i,
  }
}
