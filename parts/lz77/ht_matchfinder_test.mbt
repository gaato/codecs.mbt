///|
test "HtMatchfinder: matches are real, at least 4 bytes, and the latest repeat is found" {
  let n = 90000
  let data = repetitive(11, n)
  let mf = @lz77.HtMatchfinder()
  mf.reset(0)
  let mut found = 0
  let mut pos = 0
  while pos < n - 300 {
    let len = mf.longest_match(data, pos, 258, 32)
    assert_eq(mf.next_pos(), pos + 1)
    if len > 0 {
      assert_true(len >= 4 && len <= 258)
      check_match(data, pos, len, mf.offset())
      found += 1
      mf.skip_bytes(data, pos + 1, n, len - 1)
      pos += len
      assert_eq(mf.next_pos(), pos)
    } else {
      assert_eq(mf.offset(), 0)
      pos += 1
    }
  }
  assert_true(found > 5000)
  inspect(mf.memory_usage(), content="131072")
  // A run: the position just before matches, except the first, which
  // `reset` inserts under hash 0, as libdeflate does.
  let run = FixedArray::make(600, b'z')
  mf.reset(0)
  inspect(mf.longest_match(run, 0, 258, 258), content="0")
  inspect(mf.longest_match(run, 1, 258, 258), content="0")
  inspect(mf.longest_match(run, 2, 258, 258), content="258")
  inspect(mf.offset(), content="1")
}

///|
test "HtMatchfinder: catching up and moving the bytes change nothing" {
  let data = repetitive(12, 80000)
  let whole = @lz77.HtMatchfinder()
  whole.reset(0)
  let cut = @lz77.HtMatchfinder()
  cut.reset(0)
  let moved = FixedArray::make(80000, b'\x00')
  FixedArray::unsafe_blit(moved, 0, data, 0, 80000)
  for pos in 0..<49996 {
    ignore(whole.longest_match(data, pos, 258, 32))
    ignore(cut.longest_match(moved, pos, 258, 32))
  }
  // The cut finder skips 4 positions it cannot insert yet.
  for pos in 49996..<50000 {
    ignore(whole.longest_match(data, pos, 258, 32))
  }
  cut.skip_bytes(moved, 49996, 50000, 4)
  assert_eq(cut.next_pos(), 49996)
  let delta = 17000
  FixedArray::unsafe_blit(moved, 0, data, delta, 80000 - delta)
  cut.move_down(delta)
  cut.catch_up(moved, 50000 - delta, 80000 - delta)
  assert_eq(cut.next_pos(), 50000 - delta)
  for pos in 50000..<79000 {
    let a = whole.longest_match(data, pos, 258, 32)
    let b = cut.longest_match(moved, pos - delta, 258, 32)
    assert_eq(b, a, msg="at \{pos}")
    assert_eq(cut.offset(), whole.offset(), msg="at \{pos}")
  }
}
