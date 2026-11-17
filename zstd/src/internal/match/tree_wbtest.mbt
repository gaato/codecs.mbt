///|
test "DUBT accepts its first five-byte match at one and two MiB distances" {
  for distance in [1 << 20, 1 << 21] {
    // Level 13's large-input parameters. The candidate begins at byte 1,
    // so its distance is exactly the dictionary's length minus one.
    let finder = Tree(
      hash_log=22,
      chain_log=22,
      min_match=5,
      search_log=4,
      target_length=32,
      window_log=22,
      opt_level=-1,
    )
    let dict = b"QabcdeX" + Bytes::make(distance - 6, b'Z')
    let input = b"abcdeY0123456789"
    finder.preload(dict)
    finder.prepare(131072)
    finder.history.append(input)
    let block = @seqenc.Block()
    finder.find_buffered(input.length(), @seqenc.Repeats(), block)
    assert_eq(block.count, 1, msg="distance \{distance}")
    assert_eq(block.ll[0], 0)
    assert_eq(block.ml[0], 5)
    let @seqenc.OffsetValue(offset) = block.offsets[0]
    assert_eq(offset, (distance + 3).reinterpret_as_uint())
    assert_eq(
      Bytes::from_array(block.literals[:block.literal_count]),
      input[5:].to_owned(),
    )
  }
}

///|
test "DUBT second lookahead and immediate repeat two reconstruct their choices" {
  // A four-byte match at the cursor competes with a longer match two
  // bytes ahead. The second case makes that later choice repeat one;
  // the third instead follows the four-byte match with repeat two.
  for
    (dict, repeat, first_ll, count) in [
      (b"!ABCDx!CDEFGHIJKLMNOPQ?", 1, 2, 1),
      (b"!ABCDx!zCDEFGHIJKLMNOPQ?", 18, 2, 1),
      (b"!ABCDx!EFGHIJKLMNOPQ?", 18, 0, 2),
    ] {
    let finder = Tree(
      hash_log=10,
      chain_log=10,
      min_match=4,
      search_log=4,
      target_length=32,
      window_log=10,
      opt_level=-1,
    )
    finder.preload(dict)
    let input = b"ABCDEFGHIJKLMNOPQ!end-padding"
    finder.prepare(1024)
    finder.history.append(input)
    let repeats = @seqenc.Repeats()
    repeats.encode(@seqenc.Distance(repeat.reinterpret_as_uint()), 1) |> ignore
    let block = @seqenc.Block()
    finder.find_buffered(input.length(), repeats, block)
    assert_eq(block.count, count)
    assert_eq(block.ll[0], first_ll)
    reconstruct_matches(
      block,
      FixedArray::makei(input.length(), i => input[i]),
      dict.to_array(),
      [repeat, 1, 4],
      1024,
    )
  }
}

///|
test "sorted tree ignores a position skipped by a previous long match" {
  let finder = Tree(
    hash_log=8,
    chain_log=9,
    min_match=4,
    search_log=4,
    target_length=32,
    window_log=10,
    opt_level=0,
  )
  finder.history.append(b"abcdefghabcdefgh-padding")
  finder.all_matches(8, 24, @seqenc.Repeats(), 1)
  assert_true(finder.matches > 0)
  assert_true(finder.next_update > 8)
  finder.all_matches(8, 24, @seqenc.Repeats(), 1)
  assert_eq(finder.matches, 0)
}

///|
test "tree strategies reconstruct repeats across sliding and reset" {
  for mode in [-1, 0, 2] {
    for width in [3, 4, 5, 6] {
      let finder = Tree(
        hash_log=8,
        chain_log=9,
        min_match=width,
        search_log=4,
        target_length=32,
        window_log=10,
        opt_level=mode,
        ultra2=true,
      )
      for _ in 0..<2 {
        let repeats = @seqenc.Repeats()
        let block = @seqenc.Block()
        let frame : Array[Byte] = []
        let reps : FixedArray[Int32] = [1, 4, 8]
        let mut seed = 8878U
        for b in 0..<18 {
          let data = FixedArray::makei(997, i => {
            seed = seed * 1664525U + 1013904223U
            if b % 3 == 0 {
              (seed >> 24).to_byte()
            } else {
              ((i + b * 997) % 73).to_byte()
            }
          })
          finder.prepare(1024)
          finder.history.append_fixed(data, data.length())
          finder.find_buffered(data.length(), repeats, block)
          let scratch = if mode < 0 {
            24
          } else {
            198284 + (if width == 3 { 4 << 10 } else { 0 })
          }
          assert_eq(
            finder.memory_usage(),
            finder.history.capacity() + 4 * (256 + 512) + scratch,
          )
          reconstruct_matches(block, data, frame, reps, 1024)
          repeats.copy_from(block.repeats)
          finder.history.finish_block()
        }
        finder.reset()
      }
    }
  }
}

///|
test "tree dictionary expiry and exact-window length checks survive slides" {
  for mode in [-1, 0, 2] {
    let finder = Tree(
      hash_log=8,
      chain_log=9,
      min_match=3,
      search_log=4,
      target_length=32,
      window_log=10,
      opt_level=mode,
    )
    let dict = b"abcd".repeat(64)
    finder.preload(dict)
    let frame = dict.to_array()
    let reps : FixedArray[Int32] = [1, 4, 8]
    let repeats = @seqenc.Repeats()
    let block = @seqenc.Block()
    for i in 0..<12 {
      let data = FixedArray::makei(997, p => ((p + i * 997) % 4 + 97).to_byte())
      finder.prepare(1024)
      finder.history.append_fixed(data, data.length())
      finder.find_buffered(data.length(), repeats, block)
      reconstruct_matches(block, data, frame, reps, 1024)
      repeats.copy_from(block.repeats)
      finder.history.finish_block()
    }
    assert_eq(finder.dict_end, 0)
    assert_eq(finder.window, 1024)
    finder.reset()
    finder.history.append(b"a".repeat(1040))
    assert_eq(finder.length(1025, 0, 1040), 0)
    assert_eq(finder.length(1025, 1, 1040), 15)
    assert_eq(finder.length(1025, -1, 1040), 0)
    assert_eq(finder.length(1025, 1025, 1040), 0)
  }
}

///|
test "ultra preserves a match followed by one literal when that LL symbol is cheaper" {
  let finder = Tree(
    hash_log=8,
    chain_log=9,
    min_match=3,
    search_log=4,
    target_length=999,
    window_log=10,
    opt_level=2,
  )
  finder.preload(b"abc")
  let input = b"YabcX0123456789pq"
  finder.prepare(1024)
  finder.history.append(input)
  // Model an established stream in which single-literal sequences are
  // frequent. At the end of abc, four literals win locally, but keeping
  // the match and one following literal is cheaper at the next position.
  let prices = finder.prices
  prices.lit.fill(0)
  for c in [b'a', b'b', b'c'] {
    prices.lit[c.to_int()] = 4096
  }
  prices.lit_sum = 12288
  prices.ll.fill(1)
  prices.ll[1] = 65536
  prices.ll_sum = 65571
  prices.ml.fill(1)
  prices.ml_sum = 53
  prices.of.fill(1)
  prices.of_sum = 32
  let block = @seqenc.Block()
  finder.find_buffered(input.length(), @seqenc.Repeats(), block)
  reconstruct_matches(
    block,
    FixedArray::makei(input.length(), p => input[p]),
    b"abc".to_array(),
    [1, 4, 8],
    1024,
  )
  assert_eq(block.count, 1)
  assert_eq(block.ll[0], 1)
  assert_eq(block.ml[0], 3)
  let @seqenc.OffsetValue(offset) = block.offsets[0]
  assert_eq(offset, 2U)
}

///|
test "tree first sequences use repcodes with and without literals and repeat1 minus one" {
  for mode in [-1, 0, 2] {
    for kind in 0..<3 {
      let finder = Tree(
        hash_log=8,
        chain_log=9,
        min_match=3,
        search_log=4,
        target_length=32,
        window_log=10,
        opt_level=mode,
        ultra2=true,
      )
      let reps = @seqenc.Repeats()
      let bytes = if kind == 1 {
        b"abcd".repeat(250)
      } else {
        b"a".repeat(1000)
      }
      if kind == 1 {
        finder.preload(b"abcd")
      }
      if kind == 2 {
        finder.preload(b"a")
        reps.set(2, 4, 8)
      }
      finder.prepare(1024)
      finder.history.append(bytes)
      let block = @seqenc.Block()
      finder.find_buffered(bytes.length(), reps, block)
      assert_true(block.count > 0)
      let @seqenc.OffsetValue(code) = block.offsets[0]
      assert_eq(code, if kind == 2 { 3U } else { 1U })
      assert_eq(block.ll[0] == 0, kind > 0)
      let frame = if kind == 1 {
        b"abcd".to_array()
      } else if kind == 2 {
        b"a".to_array()
      } else {
        []
      }
      reconstruct_matches(
        block,
        FixedArray::makei(bytes.length(), i => bytes[i]),
        frame,
        if kind == 2 {
          [2, 4, 8]
        } else {
          [1, 4, 8]
        },
        4096,
      )
    }
  }
}
