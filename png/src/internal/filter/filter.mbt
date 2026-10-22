///|
/// The Paeth predictor (9.4): of `a` (left), `b` (above) and `c` (above
/// left), the one closest to `a + b - c`, ties going to `a`, then `b`.
pub fn paeth(
  a : Int32,
  b : Int32,
  c : Int32,
) -> Int32 where {
  proof_require: bytes3(a, b, c),
  proof_ensure: result => paeth_post(a, b, c, result),
} {
  let p = a + b - c
  let pa = distance(p, a)
  let pb = distance(p, b)
  let pc = distance(p, c)
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// |x − y|.
fn distance(
  x : Int32,
  y : Int32,
) -> Int32 where {
  proof_require: -512 <= x && x <= 512 && -512 <= y && y <= 512,
  proof_ensure: result => result == spec_distance(x, y),
} {
  if x >= y {
    x - y
  } else {
    y - x
  }
}

///|
/// Reverses filter type `kind` on the row in `cur[1:len + 1]`, in place,
/// against the row above in `prev[1:len + 1]` (zeros for the first row of a
/// pass). `pixel` is the bytes of a whole pixel, 1 to 8: the distance to the
/// byte on the left, which is 0 for the first `pixel` bytes. Byte 0 of each
/// array is the filter type's place and is neither read nor written, and
/// nothing past either array's end is, whatever `len` says. Returns false,
/// changing nothing, for a type other than 0 to 4.
///
/// `moon prove` checks that every index it reads and writes is inside the
/// arrays, from 1 on, and that Average's sum, halved, is a byte.
pub fn unfilter(
  kind : Byte,
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  len : Int32,
  pixel : Int32,
) -> Bool where {
  proof_require: unfilter_pre(pixel, len),
  proof_ensure: result => result == (kind.to_int() <= 4),
} {
  // SAFETY: every index below is at least 1, and below `stop`, which is at
  // most each array's length; the left neighbours, `i - pixel`, are read
  // only from `first`, where `i - pixel >= 1`. `moon prove` checks these.
  let stop = bounded_end(len, cur.length(), prev.length())
  let first = if pixel + 1 < stop { pixel + 1 } else { stop }
  if kind == b'\x00' {
    true
  } else if kind == b'\x01' {
    sub(cur, pixel, first, stop)
    true
  } else if kind == b'\x02' {
    up(cur, prev, stop)
    true
  } else if kind == b'\x03' {
    average(cur, prev, pixel, first, stop)
    true
  } else if kind == b'\x04' {
    paeth_row(cur, prev, pixel, first, stop)
    true
  } else {
    false
  }
}

///|
/// One past the last index of the row: `len + 1`, but within both arrays.
fn bounded_end(
  len : Int32,
  cur : Int32,
  prev : Int32,
) -> Int32 where {
  proof_require: 0 <= cur && 0 <= prev,
  proof_ensure: result => end_post(len, cur, prev, result),
} {
  let stop = if len + 1 < cur { len + 1 } else { cur }
  if stop < prev {
    stop
  } else {
    prev
  }
}

///|
/// Sub (9.3): each byte plus the one `pixel` bytes to its left.
fn sub(
  cur : FixedArray[Byte],
  pixel : Int32,
  first : Int32,
  stop : Int32,
) -> Unit where {
  proof_require: rows_pre(cur.length(), cur.length(), pixel, first, stop),
  proof_ensure: true,
} {
  for i = first; i < stop; {
    proof_assert in_row(i, cur.length()) && in_row(i - pixel, cur.length())
    cur.unsafe_set(i, byte_add(cur.unsafe_get(i), cur.unsafe_get(i - pixel)))
    continue i + 1
  } where {
    proof_invariant: first <= i,
  }
}

///|
/// Up: each byte plus the one above it.
fn up(
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  stop : Int32,
) -> Unit where {
  proof_require: 0 <= stop && stop <= cur.length() && stop <= prev.length(),
  proof_ensure: true,
} {
  for i = 1; i < stop; {
    proof_assert in_row(i, cur.length()) && in_row(i, prev.length())
    cur.unsafe_set(i, byte_add(cur.unsafe_get(i), prev.unsafe_get(i)))
    continue i + 1
  } where {
    proof_invariant: 1 <= i,
  }
}

///|
/// Average: each byte plus the mean, rounded down, of the one to its left
/// (0 for the first `pixel` bytes) and the one above.
fn average(
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  pixel : Int32,
  first : Int32,
  stop : Int32,
) -> Unit where {
  proof_require: rows_pre(cur.length(), prev.length(), pixel, first, stop),
  proof_ensure: true,
} {
  for i = 1; i < first; {
    proof_assert in_row(i, cur.length()) && in_row(i, prev.length())
    let half = @proof_bits.shr(prev.unsafe_get(i).to_int(), 1)
    cur.unsafe_set(i, byte_add(cur.unsafe_get(i), byte_of(half)))
    continue i + 1
  } where {
    proof_invariant: 1 <= i,
  }
  for i = first; i < stop; {
    proof_assert in_row(i, cur.length()) && in_row(i - pixel, cur.length())
    proof_assert in_row(i, prev.length())
    let sum = cur.unsafe_get(i - pixel).to_int() + prev.unsafe_get(i).to_int()
    let half = @proof_bits.shr(sum, 1)
    cur.unsafe_set(i, byte_add(cur.unsafe_get(i), byte_of(half)))
    continue i + 1
  } where {
    proof_invariant: first <= i,
  }
}

///|
/// Paeth: each byte plus `paeth` of the one to its left, the one above and
/// the one above left (0 for the first `pixel` bytes, where the predictor is the
/// byte above).
fn paeth_row(
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  pixel : Int32,
  first : Int32,
  stop : Int32,
) -> Unit where {
  proof_require: rows_pre(cur.length(), prev.length(), pixel, first, stop),
  proof_ensure: true,
} {
  for i = 1; i < first; {
    proof_assert in_row(i, cur.length()) && in_row(i, prev.length())
    cur.unsafe_set(i, byte_add(cur.unsafe_get(i), prev.unsafe_get(i)))
    continue i + 1
  } where {
    proof_invariant: 1 <= i,
  }
  for i = first; i < stop; {
    proof_assert in_row(i, cur.length()) && in_row(i - pixel, cur.length())
    proof_assert in_row(i, prev.length()) && in_row(i - pixel, prev.length())
    let p = paeth(
      cur.unsafe_get(i - pixel).to_int(),
      prev.unsafe_get(i).to_int(),
      prev.unsafe_get(i - pixel).to_int(),
    )
    cur.unsafe_set(i, byte_add(cur.unsafe_get(i), byte_of(p)))
    continue i + 1
  } where {
    proof_invariant: first <= i,
  }
}
