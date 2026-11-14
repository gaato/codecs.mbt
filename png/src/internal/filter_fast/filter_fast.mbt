///|
/// Reverses filter type `kind` on the current row `cur` against the row
/// above, `prev`, as `@filter.unfilter` does, with the same arguments,
/// precondition and result: byte 0 of both rows is the filter type's place,
/// left alone, and nothing past `len + 1` or either row's end is read or
/// written.
///
/// The Up filter (type 2) runs sixteen bytes at a time with SIMD, and Sub,
/// Average and Paeth (1, 3 and 4) a pixel at a time for pixels of 3 and 4
/// bytes, 8-bit RGB and RGBA; `@filter.unfilter` does the rest.
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
  } else if (kind == b'\x01' || kind == b'\x03' || kind == b'\x04') &&
    (pixel == 3 || pixel == 4) {
    let stop = bounded_end(len, cur.length(), prev.length())
    // The pixel loops read sixteen bytes from the pixel after the one they
    // reverse, past the first pixel: they need that many in the row. A sum,
    // not a difference: `stop` is negative when `len + 1` wrapped, and
    // `stop - 1 - pixel` would wrap back to a large number.
    if stop >= pixel + pixel + 17 {
      pixels(kind, cur, prev, pixel, stop)
      true
    } else {
      @filter.unfilter(kind, cur, prev, len, pixel)
    }
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

///|
/// Sub, Average or Paeth (`kind` 1, 3 or 4) over `cur[1:stop]`, a pixel of
/// `pixel` (3 or 4) bytes at a time: the first pixel and the last bytes
/// through `@filter.unfilter_range`, the pixels between with SIMD.
///
/// Each pixel's bytes are reversed together in the lanes of one vector,
/// from the pixel on the left (`a`), the one above (`b`) and the one above
/// left (`c`), and the first four lanes are stored. For 3-byte pixels the
/// fourth lane lands on the next pixel's first byte, which is why each
/// step reads the next pixel, and the one above it, before it stores, and
/// the loop ends by storing the next pixel's bytes back as they were read.
/// Read in that order, the bytes are those the one-byte loop reads, should
/// `prev` be `cur`.
#cfg(any(target="native", target="wasm"))
fn pixels(
  kind : Byte,
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  pixel : Int32,
  stop : Int32,
) -> Unit where {
  proof_require: 3 <= pixel &&
  pixel <= 4 &&
  stop <= cur.length() &&
  stop <= prev.length() &&
  stop >= pixel + pixel + 17,
  proof_ensure: true,
} {
  let first = pixel + 1
  @filter.unfilter_range(kind, cur, prev, pixel, 1, first)
  // Not `end`, a keyword of WhyML, which `moon prove` writes this into.
  let rest = if kind == b'\x01' {
    sub_pixels(cur, pixel, first, stop)
  } else if kind == b'\x03' {
    average_pixels(cur, prev, pixel, first, stop)
  } else {
    paeth_pixels(cur, prev, pixel, first, stop)
  }
  @filter.unfilter_range(kind, cur, prev, pixel, rest, stop)
}

///|
/// Sub from `first` while sixteen bytes remain after the next pixel;
/// returns where it stopped. The prediction is the pixel on the left.
#cfg(any(target="native", target="wasm"))
fn sub_pixels(
  cur : FixedArray[Byte],
  pixel : Int32,
  first : Int32,
  stop : Int32,
) -> Int32 where {
  proof_require: 3 <= pixel &&
  pixel <= 4 &&
  first == pixel + 1 &&
  stop <= cur.length() &&
  stop - first >= pixel + 16,
  proof_ensure: result => first <= result && result <= stop,
} {
  // While sixteen bytes remain after the next pixel, `i + pixel + 16 <=
  // stop`: written as `i < limit`, the form whose end `moon prove` sees.
  let limit = stop - pixel - 15
  let a = load16(cur, 1)
  let x = load16(cur, first)
  for i = first, a = a, x = x; i < limit; {
    let next = load16(cur, i + pixel)
    let r = add16(x, a)
    store4(cur, i, r)
    continue i + pixel, r, next
  } nobreak {
    store4(cur, i, x)
    i
  } where {
    proof_invariant: first <= i && stop - i >= 16,
  }
}

///|
/// Average from `first`, as `sub_pixels`; the prediction is the mean of the
/// pixel on the left and the one above, rounded down.
#cfg(any(target="native", target="wasm"))
fn average_pixels(
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  pixel : Int32,
  first : Int32,
  stop : Int32,
) -> Int32 where {
  proof_require: 3 <= pixel &&
  pixel <= 4 &&
  first == pixel + 1 &&
  stop <= cur.length() &&
  stop <= prev.length() &&
  stop - first >= pixel + 16,
  proof_ensure: result => first <= result && result <= stop,
} {
  // While sixteen bytes remain after the next pixel, `i + pixel + 16 <=
  // stop`: written as `i < limit`, the form whose end `moon prove` sees.
  let limit = stop - pixel - 15
  let a = load16(cur, 1)
  let x = load16(cur, first)
  let b = load16(prev, first)
  for i = first, a = a, x = x, b = b; i < limit; {
    let next = load16(cur, i + pixel)
    let next_b = load16(prev, i + pixel)
    let r = add16(x, avg16(a, b))
    store4(cur, i, r)
    continue i + pixel, r, next, next_b
  } nobreak {
    store4(cur, i, x)
    i
  } where {
    proof_invariant: first <= i && stop - i >= 16,
  }
}

///|
/// Paeth from `first`, as `sub_pixels`; the prediction is `paeth16` of the
/// pixel on the left, the one above and the one above left.
#cfg(any(target="native", target="wasm"))
fn paeth_pixels(
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  pixel : Int32,
  first : Int32,
  stop : Int32,
) -> Int32 where {
  proof_require: 3 <= pixel &&
  pixel <= 4 &&
  first == pixel + 1 &&
  stop <= cur.length() &&
  stop <= prev.length() &&
  stop - first >= pixel + 16,
  proof_ensure: result => first <= result && result <= stop,
} {
  // While sixteen bytes remain after the next pixel, `i + pixel + 16 <=
  // stop`: written as `i < limit`, the form whose end `moon prove` sees.
  let limit = stop - pixel - 15
  let a = load16(cur, 1)
  let x = load16(cur, first)
  let b = load16(prev, first)
  for i = first, a = a, x = x, b = b; i < limit; {
    let next = load16(cur, i + pixel)
    let next_b = load16(prev, i + pixel)
    // Above left is read afresh, after the store on the left, as the
    // one-byte loop reads it.
    let r = add16(x, paeth16(a, b, load16(prev, i - pixel)))
    store4(cur, i, r)
    continue i + pixel, r, next, next_b
  } nobreak {
    store4(cur, i, x)
    i
  } where {
    proof_invariant: first <= i && stop - i >= 16,
  }
}
