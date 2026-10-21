// Generated from parts/lz77/hc_matchfinder_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
/// Bytes from a small alphabet, with repeats from up to 40,000 back, so that
/// matches of every length and many beyond the window come up.
fn repetitive(seed : Int32, n : Int32) -> FixedArray[Byte] {
  let data = FixedArray::make(n, b'\x00')
  let mut state = seed
  let next = (bound : Int32) => {
    state = (state * 1103515245 + 12345) & 0x7fff_ffff
    (state >> 8) % bound
  }
  let mut i = 0
  while i < n {
    if i > 8 && next(3) != 0 {
      let back = 1 + next(i.min(40000))
      let len = (3 + next(40)).min(n - i)
      for k in 0..<len {
        data[i + k] = data[i + k - back]
      }
      i += len
    } else {
      data[i] = (b'a'.to_int() + next(6)).to_byte()
      i += 1
    }
  }
  data
}

///|
/// The longest match at `pos` of at least 4 bytes within the window, at most
/// `max_len`, by trying every earlier position.
fn longest_by_search(
  data : FixedArray[Byte],
  pos : Int32,
  max_len : Int32,
) -> Int32 {
  let mut best = 0
  for m = (pos - @lz77.WINDOW + 1).max(0); m < pos; m = m + 1 {
    best = best.max(@lz77.match_length(data, m, pos, max_len))
  }
  if best < 4 {
    0
  } else {
    best
  }
}

///|
fn check_match(
  data : FixedArray[Byte],
  pos : Int32,
  len : Int32,
  offset : Int32,
) -> Unit raise {
  assert_true(offset >= 1 && offset < @lz77.WINDOW, msg="offset \{offset}")
  for k in 0..<len {
    assert_eq(data[pos + k], data[pos - offset + k], msg="at \{pos}")
  }
}

///|
test "HcMatchfinder: with no depth limit it finds every longest match of 4 or more" {
  let n = 90000
  let data = repetitive(7, n)
  let mf = @lz77.HcMatchfinder()
  mf.reset(0)
  let mut checked = 0
  for pos in 0..<(n - 300) {
    let len = mf.longest_match(data, pos, 2, 258, 258, 1 << 20)
    if len >= 3 {
      check_match(data, pos, len, mf.offset())
    }
    // A sample of the positions, against a full search.
    if pos % 97 == 0 && pos > 0 {
      let best = longest_by_search(data, pos, 258)
      if best >= 4 {
        assert_eq(len, best, msg="at \{pos}")
      }
      checked += 1
    }
  }
  assert_true(checked > 900)
  inspect(mf.memory_usage(), content="262144")
}

///|
test "HcMatchfinder: skipping, depth, nice length and a short end" {
  let data = repetitive(8, 50000)
  let mf = @lz77.HcMatchfinder()
  mf.reset(0)
  let mut pos = 0
  while pos < 49000 {
    let len = mf.longest_match(data, pos, 2, 258, 30, 4)
    assert_true(len <= 258)
    if len >= 3 {
      check_match(data, pos, len, mf.offset())
      // A match of `nice_len` or more ends the search.
      mf.skip_bytes(data, pos + 1, 50000, len - 1)
      pos += len
    } else {
      pos += 1
    }
    assert_eq(mf.next_pos(), pos)
  }
  // Too few bytes before the end: nothing is inserted.
  mf.skip_bytes(data, pos, pos + 6, 2)
  assert_eq(mf.next_pos(), pos)
  inspect(mf.longest_match(data, pos, 2, 4, 4, 10), content="2")
  inspect(mf.offset(), content="0")
  assert_eq(mf.next_pos(), pos)
}

///|
test "HcMatchfinder: positions left out near the end are caught up, and moving the bytes changes nothing" {
  let data = repetitive(9, 80000)
  // One finder stops 3 bytes short of a cut at 50,000 and catches up once
  // more bytes come, over a buffer that is moved down 17,000 bytes, keeping the window; the
  // other sees everything at once.
  let whole = @lz77.HcMatchfinder()
  whole.reset(0)
  let cut = @lz77.HcMatchfinder()
  cut.reset(0)
  let moved = FixedArray::make(80000, b'\x00')
  FixedArray::unsafe_blit(moved, 0, data, 0, 80000)
  for pos in 0..<49997 {
    ignore(whole.longest_match(data, pos, 2, 258, 258, 50))
    ignore(cut.longest_match(moved, pos, 2, 258, 258, 50))
  }
  for pos in 49997..<50000 {
    ignore(whole.longest_match(data, pos, 2, 258, 258, 50))
    assert_eq(cut.longest_match(moved, pos, 2, 50000 - pos, 3, 50), 2)
  }
  assert_eq(cut.next_pos(), 49997)
  // Nothing to catch up with a cut so close.
  cut.catch_up(moved, 50000, 50002)
  assert_eq(cut.next_pos(), 49997)
  let delta = 17000
  FixedArray::unsafe_blit(moved, 0, data, delta, 80000 - delta)
  cut.move_down(delta)
  cut.catch_up(moved, 50000 - delta, 80000 - delta)
  assert_eq(cut.next_pos(), 50000 - delta)
  for pos in 50000..<79000 {
    let a = whole.longest_match(data, pos, 2, 258, 258, 50)
    let b = cut.longest_match(moved, pos - delta, 2, 258, 258, 50)
    assert_eq(b, a, msg="at \{pos}")
    if a >= 3 {
      assert_eq(cut.offset(), whole.offset(), msg="at \{pos}")
    }
  }
}

///|
test "the matchfinders read nothing at or past in_end" {
  // The same bytes before a cut, then two different tails: what the finders
  // do up to the cut, told it is the end, cannot depend on the tail.
  let n = 70000
  let cut = 66000
  let a = repetitive(13, n)
  let b = FixedArray::make(n, b'\x00')
  FixedArray::unsafe_blit(b, 0, a, 0, cut)
  for i in cut..<n {
    b[i] = (a[i].to_int() ^ 0x5a).to_byte()
  }
  let runs = [a, b].map(data => {
    let hc = @lz77.HcMatchfinder()
    hc.reset(0)
    let ht = @lz77.HtMatchfinder()
    ht.reset(0)
    let found = []
    let mut pos = 0
    while pos < cut {
      let max_len = (cut - pos).min(258)
      let len = hc.longest_match(data, pos, 2, max_len, max_len, 1 << 20)
      found.push(len)
      found.push(hc.offset())
      if max_len >= @lz77.REQUIRED_BYTES {
        found.push(ht.longest_match(data, pos, max_len, max_len))
        found.push(ht.offset())
      }
      if len >= 3 {
        hc.skip_bytes(data, pos + 1, cut, len - 1)
        ht.skip_bytes(data, pos + 1, cut, len - 1)
        pos += len
      } else {
        pos += 1
      }
    }
    hc.catch_up(data, cut, cut)
    ht.catch_up(data, cut, cut)
    found.push(hc.next_pos())
    found.push(ht.next_pos())
    found
  })
  assert_eq(runs[0], runs[1])
}
