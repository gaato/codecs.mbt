///|
/// Deterministic bytes (an LCG), so that a failure reproduces.
fn lcg(seed : Int32) -> () -> Byte {
  let mut s = seed
  () => {
    s = (s * 1103515245 + 12345) & 0x7FFFFFFF
    (s >> 16).to_byte()
  }
}

///|
/// `@filter_fast.unfilter` and `@filter.unfilter` on copies of the same rows:
/// the same result, and the same bytes in both rows after.
fn check(
  kind : Int32,
  cur : FixedArray[Byte],
  prev : FixedArray[Byte],
  len : Int32,
  unit : Int32,
) -> Unit raise {
  let cur_fast = cur.copy()
  let prev_fast = prev.copy()
  let cur_ref = cur.copy()
  let prev_ref = prev.copy()
  let got = @filter_fast.unfilter(
    kind.to_byte(),
    cur_fast,
    prev_fast,
    len,
    unit,
  )
  let want = @filter.unfilter(kind.to_byte(), cur_ref, prev_ref, len, unit)
  let what = "kind=\{kind} rows=\{cur.length()},\{prev.length()} len=\{len} unit=\{unit}"
  assert_eq(got, want, msg=what)
  assert_true(cur_fast == cur_ref, msg=what)
  assert_true(prev_fast == prev_ref, msg=what)
}

///|
test "equal to @filter.unfilter: every type and pixel size, rows of 0 to 40 bytes and an image's" {
  let next = lcg(12345)
  let lens = Array::makei(41, i => i)
  lens.push(1536)
  for unit in [1, 2, 3, 4, 6, 8] {
    for len in lens {
      let cur = FixedArray::makei(len + 1, _ => next())
      let prev = FixedArray::makei(len + 1, _ => next())
      for kind in 0..<7 {
        check(kind, cur, prev, len, unit)
      }
    }
  }
}

///|
test "equal to @filter.unfilter when len and the rows' lengths disagree" {
  let next = lcg(777)
  for
    sizes in [(30, 23), (23, 30), (17, 17), (48, 33), (1, 40), (40, 1), (0, 5)] {
    let (c, p) = sizes
    let cur = FixedArray::makei(c, _ => next())
    let prev = FixedArray::makei(p, _ => next())
    for len in [-1, 0, 15, 16, 17, 22, 29, 32, 100, 2147483646, 2147483647] {
      for kind in 0..<5 {
        check(kind, cur, prev, len, 3)
      }
    }
  }
}

///|
test "nothing past either row's end is read or written, whatever len says" {
  for kind in 0..<5 {
    let cur = FixedArray::make(40, b'\x01')
    let prev = FixedArray::make(19, b'\x02')
    // `len` past both arrays: only bytes 1 to 18, which both have, change.
    assert_true(@filter_fast.unfilter(kind.to_byte(), cur, prev, 100, 1))
    for i in 19..<40 {
      assert_eq(cur[i], b'\x01')
    }
    assert_eq(cur[0], b'\x01')
  }
}

///|
test "a len whose len + 1 overflows reads and writes nothing" {
  // `len + 1` wraps to the most negative Int: the reference reverses
  // nothing, and so must the SIMD loop, whose bound must not wrap back.
  for kind in 0..<5 {
    let cur = FixedArray::make(40, b'\x01')
    let prev = FixedArray::make(40, b'\x02')
    let _ = @filter_fast.unfilter(kind.to_byte(), cur, prev, 2147483647, 1)
    assert_true(cur.iter().all(b => b == b'\x01'), msg="kind \{kind}")
  }
}

///|
test "the pixel loops equal @filter.unfilter: RGB and RGBA rows of 0 to 200 bytes, random and extreme" {
  let next = lcg(4242)
  let patterns : Array[(Int32) -> Byte] = [
    _ => next(),
    _ => b'\x00',
    _ => b'\xff',
    i => if i % 2 == 0 { b'\x00' } else { b'\xff' },
    i => (i * 37 % 256).to_byte(),
    i => if i % 3 == 0 { b'\x80' } else { b'\x7f' },
  ]
  for unit in [3, 4] {
    for len in 0..<=200 {
      for pc in patterns {
        for pp in patterns {
          let cur = FixedArray::makei(len + 1, pc)
          let prev = FixedArray::makei(len + 1, pp)
          for kind in [1, 3, 4] {
            check(kind, cur, prev, len, unit)
          }
        }
      }
    }
  }
}

///|
test "the pixel loops equal @filter.unfilter when cur is prev" {
  let next = lcg(99)
  for unit in [3, 4] {
    for len in [0, 23, 24, 40, 100, 1536] {
      for kind in [1, 3, 4] {
        let fast = FixedArray::makei(len + 1, _ => next())
        let reference = fast.copy()
        let got = @filter_fast.unfilter(kind.to_byte(), fast, fast, len, unit)
        let want = @filter.unfilter(
          kind.to_byte(),
          reference,
          reference,
          len,
          unit,
        )
        assert_eq(got, want)
        assert_true(
          fast == reference,
          msg="kind=\{kind} len=\{len} unit=\{unit}",
        )
      }
    }
  }
}

///|
test "the pixel loops read and write nothing past either row's end" {
  for unit in [3, 4] {
    for kind in [1, 3, 4] {
      let cur = FixedArray::make(80, b'\x01')
      let prev = FixedArray::make(61, b'\x02')
      assert_true(@filter_fast.unfilter(kind.to_byte(), cur, prev, 100, unit))
      for i in 61..<80 {
        assert_eq(cur[i], b'\x01')
      }
      assert_eq(cur[0], b'\x01')
      // A row that ends inside cur: the bytes after it stay.
      let cur = FixedArray::make(80, b'\x01')
      let prev = FixedArray::make(80, b'\x02')
      assert_true(@filter_fast.unfilter(kind.to_byte(), cur, prev, 50, unit))
      for i in 51..<80 {
        assert_eq(cur[i], b'\x01', msg="kind=\{kind} unit=\{unit} i=\{i}")
      }
    }
  }
}
