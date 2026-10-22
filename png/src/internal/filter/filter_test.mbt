///|
/// The Paeth predictor as 9.4 writes it.
fn paeth_of_9_4(a : Int32, b : Int32, c : Int32) -> Int32 {
  let p = a + b - c
  let pa = if p > a { p - a } else { a - p }
  let pb = if p > b { p - b } else { b - p }
  let pc = if p > c { p - c } else { c - p }
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// Filter type `kind` applied to `row` (the bytes of a row, without the
/// filter type) against `above`, as an encoder applies it (9.2).
fn apply(
  kind : Int32,
  row : Array[Byte],
  above : Array[Byte],
  unit : Int32,
) -> Array[Byte] {
  let out = []
  for i in 0..<row.length() {
    let x = row[i].to_int()
    let a = if i >= unit { row[i - unit].to_int() } else { 0 }
    let b = above[i].to_int()
    let c = if i >= unit { above[i - unit].to_int() } else { 0 }
    let predicted = match kind {
      0 => 0
      1 => a
      2 => b
      3 => (a + b) / 2
      _ => paeth_of_9_4(a, b, c)
    }
    out.push((x - predicted).to_byte())
  }
  out
}

///|
test "paeth: ties go to a, then b, as 9.4 says" {
  // a, b and c over a lattice that crosses every tie.
  for a = 0; a < 256; a = a + 5 {
    for b = 0; b < 256; b = b + 3 {
      for c = 0; c < 256; c = c + 7 {
        assert_eq(@filter.paeth(a, b, c), paeth_of_9_4(a, b, c))
      }
    }
  }
  inspect(@filter.paeth(10, 10, 10), content="10")
  inspect(@filter.paeth(3, 5, 4), content="4")
  inspect(@filter.paeth(1, 10, 3), content="10")
  inspect(@filter.paeth(0, 9, 0), content="9")
  inspect(@filter.paeth(9, 0, 0), content="9")
  inspect(@filter.paeth(0, 0, 9), content="0")
}

///|
test "unfilter: every filter type, every pixel size, reverses the encoder's filter" {
  let mut seed = 12345
  let next = () => {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    (seed >> 16).to_byte()
  }
  for unit in [1, 2, 3, 4, 6, 8] {
    for len in [1, 2, 5, 17, 64] {
      let above = Array::makei(len, _ => next())
      let row = Array::makei(len, _ => next())
      for kind in 0..<5 {
        let filtered = apply(kind, row, above, unit)
        let cur = FixedArray::make(len + 1, b'\xee')
        let prev = FixedArray::make(len + 1, b'\xdd')
        for i in 0..<len {
          cur[i + 1] = filtered[i]
          prev[i + 1] = above[i]
        }
        assert_true(@filter.unfilter(kind.to_byte(), cur, prev, len, unit))
        for i in 0..<len {
          assert_eq(cur[i + 1], row[i])
          assert_eq(prev[i + 1], above[i])
        }
        // Byte 0 is the filter type's place, left alone.
        assert_eq(cur[0], b'\xee')
      }
    }
  }
}

///|
test "unfilter: a type past 4 is refused, the row unchanged" {
  for kind in [b'\x05', b'\x80', b'\xff'] {
    let cur = FixedArray::make(4, b'\x01')
    let prev = FixedArray::make(4, b'\x02')
    assert_false(@filter.unfilter(kind, cur, prev, 3, 1))
    assert_true(cur.iter().all(b => b == b'\x01'))
  }
}

///|
test "unfilter: nothing past either row's end is read or written, whatever len says" {
  for kind in 0..<5 {
    let cur = FixedArray::make(4, b'\x01')
    let prev = FixedArray::make(3, b'\x02')
    // `len` past both arrays: only bytes 1 and 2, which both have, change.
    assert_true(@filter.unfilter(kind.to_byte(), cur, prev, 100, 1))
    assert_eq(cur[3], b'\x01')
  }
}
