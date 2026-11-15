///|
/// Bytes that repeat every 64: a later copy matches an earlier one at any
/// distance that is a multiple of 64.
fn periodic(n : Int32) -> Bytes {
  Bytes::makei(n, i => (i % 64 * 3 + 7).to_byte())
}

///|
/// Runs `blocks` blocks of `block` bytes through a finder's history after a
/// dictionary of `dict` bytes, a 1 KiB window: `state()` gives the finder's
/// reach and dictionary end after each `prepare`, and `reach(p, q)` the
/// match length the finder accepts from `p` back to `q`.
fn walk(
  prepare : (Int32) -> Unit,
  history : History,
  state : () -> (Int32, Int32),
  reach : (Int32, Int32, Int32) -> Int32,
  dict : Int32,
) -> Unit raise {
  let window = 1024
  let block = 512
  let input = periodic(block)
  assert_eq(state(), (window + dict, dict))
  // Once out of reach, the dictionary stays so, though `prepare` then moves
  // the history down.
  let mut gone = false
  for i in 0..<12 {
    let before = history.start
    let in_reach = !gone && before + block <= dict + window
    gone = !in_reach
    prepare(block)
    let start = history.start
    let (limit, dict_end) = state()
    if in_reach {
      // In reach: the whole dictionary, however far back.
      assert_eq((limit, dict_end), (window + dict, dict), msg="block \{i}")
    } else {
      // Out of reach once a block would end a window past it.
      assert_eq((limit, dict_end), (window, 0), msg="block \{i}")
    }
    history.append(input[:])
    let end = start + block
    // A match from the block's start into the dictionary's first bytes:
    // accepted while the dictionary is in reach, refused after.
    let far = reach(start, 0, end)
    if in_reach {
      assert_true(far > 0, msg="far \{i}")
    } else if start > window {
      assert_eq(far, 0, msg="far \{i}")
    }
    history.finish_block()
  }
}

///|
test "every finder reaches into a preloaded dictionary until a window past it" {
  // 48 periods: a block starts in phase with the dictionary's first byte.
  let dict = periodic(3072)
  let fast = Fast(hash_log=12, min_match=5, target_length=0, window_log=10)
  fast.preload(dict[:])
  walk(
    n => fast.prepare(n),
    fast.history,
    () => (fast.window, fast.dict_end),
    (p, q, end) => fast.length(p, q, end),
    dict.length(),
  )
  let dfast = Dfast(hash_log=12, chain_log=11, min_match=5, window_log=10)
  dfast.preload(dict[:])
  walk(
    n => dfast.prepare(n),
    dfast.history,
    () => (dfast.window, dfast.dict_end),
    (p, q, end) => dfast.length(p, q, end),
    dict.length(),
  )
  for row in [false, true] {
    let finder = Lazy(
      hash_log=12,
      chain_log=11,
      min_match=5,
      search_log=4,
      depth=1,
      window_log=10,
      row_finder=row,
    )
    finder.preload(dict[:])
    walk(
      n => finder.prepare(n),
      finder.history,
      () => (finder.window, finder.dict_end),
      (p, q, end) => finder.length(p, q, end),
      dict.length(),
    )
    // A reset forgets the dictionary until it is preloaded again.
    finder.reset()
    assert_eq((finder.window, finder.dict_end), (1024, 0))
  }
}

///|
test "an empty dictionary changes nothing" {
  let fast = Fast(hash_log=12, min_match=5, target_length=0, window_log=10)
  fast.preload(b""[:])
  assert_eq((fast.window, fast.dict_end), (1024, 0))
  let dfast = Dfast(hash_log=12, chain_log=11, min_match=5, window_log=10)
  dfast.preload(b""[:])
  assert_eq((dfast.window, dfast.dict_end), (1024, 0))
  let finder = Lazy(
    hash_log=12,
    chain_log=11,
    min_match=5,
    search_log=4,
    depth=1,
    window_log=10,
  )
  finder.preload(b""[:])
  assert_eq((finder.window, finder.dict_end), (1024, 0))
}
