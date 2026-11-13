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
