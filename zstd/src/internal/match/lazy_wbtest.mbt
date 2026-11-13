///|
/// Execute RFC offsets independently of Repeats::resolve and compare every
/// byte, including overlapping copies. History here retains the whole frame
/// so a bad distance cannot be hidden by the finder's own sliding buffer.
fn reconstruct_matches(
  block : @seqenc.Block,
  expected : FixedArray[Byte],
  frame : Array[Byte],
  reps : FixedArray[Int32],
  window : Int32,
) -> Unit raise {
  let start = frame.length()
  let mut literal = 0
  for i in 0..<block.count {
    for _ in 0..<block.ll[i] {
      frame.push(block.literals[literal])
      literal += 1
    }
    let @seqenc.OffsetValue(v) = block.offsets[i]
    let code = v.reinterpret_as_int()
    let distance = if code > 3 {
      let d = code - 3
      reps[2] = reps[1]
      reps[1] = reps[0]
      reps[0] = d
      d
    } else {
      let index = code - 1 + (if block.ll[i] == 0 { 1 } else { 0 })
      let d = if index == 3 { reps[0] - 1 } else { reps[index] }
      if index != 0 {
        if index != 1 {
          reps[2] = reps[1]
        }
        reps[1] = reps[0]
        reps[0] = d
      }
      d
    }
    assert_true(
      distance > 0 && distance <= window && distance <= frame.length(),
    )
    for _ in 0..<block.ml[i] {
      frame.push(frame[frame.length() - distance])
    }
  }
  for i in literal..<block.literal_count {
    frame.push(block.literals[i])
  }
  assert_eq(
    frame[start:].to_owned(),
    Array::makei(expected.length(), i => expected[i]),
  )
}

///|
test "lazy depths reconstruct across history rebasing and frame reset" {
  for row_finder in [false, true] {
    for depth in 0..<=2 {
      for width in [3, 4, 5, 6] {
        let finder = Lazy(
          hash_log=8,
          chain_log=8,
          min_match=width,
          search_log=4,
          depth~,
          window_log=10,
          row_finder~,
        )
        let repeats = @seqenc.Repeats()
        let block = @seqenc.Block()
        let frame : Array[Byte] = []
        let reps : FixedArray[Int32] = [1, 4, 8]
        let mut seed = 8878U
        for b in 0..<40 {
          let data = FixedArray::makei(997, i => {
            seed = seed * 1664525 + 1013904223
            if b % 3 == 0 {
              (seed >> 24).to_byte()
            } else {
              ((i + b * 997) % 251).to_byte()
            }
          })
          finder.find(data, data.length(), repeats, block)
          reconstruct_matches(block, data, frame, reps, 1024)
          repeats.copy_from(block.repeats)
          assert_true(
            finder.history.start >= ((b + 1) * 997).min(1024) &&
            finder.history.start <= 3072,
          )
          assert_true(finder.memory_usage() <= 3072 + 8 * 256)
          for q in finder.hash {
            assert_true(q >= -1 && q < finder.history.start)
          }
          for q in finder.chain {
            assert_true(q >= -1 && q < finder.history.start)
          }
        }
        finder.reset()
        repeats.reset()
        finder.find([], 0, repeats, block)
        assert_eq(block.count, 0)
        finder.find([b'a', b'b', b'c'], 3, repeats, block)
        assert_eq(block.literal_count, 3)
        assert_eq(finder.bias, 0)
      }
    }
  }
}

///|
test "lazy chooses a longer later match while greedy keeps the first" {
  // At the second ABCD, a four-byte match competes with the 17-byte
  // BCDE... match one byte ahead. Catch-back cannot cross x versus A.
  let bytes = b"!ABCDx!BCDEFGHIJKLMNOPQ?ABCDEFGHIJKLMNOPQ!end-padding"
  let data = FixedArray::makei(bytes.length(), i => bytes[i])
  let starts : Array[Int32] = []
  for depth in 0..<=2 {
    let finder = Lazy(
      hash_log=12,
      chain_log=10,
      min_match=4,
      search_log=4,
      depth~,
      window_log=10,
    )
    let block = @seqenc.Block()
    finder.find(data, data.length(), @seqenc.Repeats(), block)
    reconstruct_matches(block, data, [], [1, 4, 8], 1024)
    starts.push(block.ll[0])
  }
  debug_inspect(starts, content="[24, 25, 25]")
}

///|
test "hash chain search stops at searchLog and ring limits" {
  for log in [0, 1, 2, 3] {
    let f = Lazy(
      hash_log=6,
      chain_log=10,
      min_match=4,
      search_log=log,
      depth=2,
      window_log=10,
    )
    f.history.data = FixedArray::make(400, b'x')
    // All candidates share four bytes; the oldest alone matches 20.
    for p in [32, 64, 96, 128, 160, 192, 224, 256] {
      f.history.data[p + 4] = b'y'
    }
    for i in 0..<20 {
      f.history.data[32 + i] = f.history.data[300 + i]
    }
    let h = f.hash_at(300)
    f.hash[h] = 256
    for p in [256, 224, 192, 160, 128, 96, 64] {
      f.chain[f.slot(p)] = p - 32
    }
    f.next_update = 300
    // The head may be older than the ring; it can be checked once but its
    // overwritten link must never be followed.
    f.search(300, 320, false)
    assert_eq(
      (f.match_length, f.match_distance),
      if log < 3 {
        (4, 44)
      } else {
        (20, 268)
      },
    )
    f.hash[h] = 32
    f.search(300, 320, false)
    assert_eq((f.match_length, f.match_distance), (20, 268))
    assert_eq(f.length(300, -1, 320), 0)
    assert_eq(f.length(300, 300, 320), 0)
  }
  let f = Lazy(
    hash_log=6,
    chain_log=10,
    min_match=4,
    search_log=1,
    depth=0,
    window_log=10,
  )
  f.history.data = FixedArray::make(1100, b'x')
  f.next_update = 1050
  f.hash[f.hash_at(1050)] = 26
  f.search(1050, 1060, false)
  assert_eq((f.match_length, f.match_distance), (10, 1024))
  f.hash[f.hash_at(1050)] = 25
  f.search(1050, 1060, false)
  assert_eq((f.match_length, f.match_distance), (3, 0))
}

///|
test "greedy repeat one wins before chain search and repeat two is immediate" {
  for depth in 0..<=2 {
    let f = Lazy(
      hash_log=10,
      chain_log=10,
      min_match=4,
      search_log=3,
      depth~,
      window_log=10,
    )
    let repeats = @seqenc.Repeats()
    let block = @seqenc.Block()
    let frame : Array[Byte] = []
    let reps : FixedArray[Int32] = [1, 4, 8]
    let first = FixedArray::makei(1000, i => (i % 19).to_byte())
    f.find(first, 1000, repeats, block)
    reconstruct_matches(block, first, frame, reps, 1024)
    repeats.copy_from(block.repeats)
    let next = FixedArray::makei(1000, i => ((i + 1000) % 19).to_byte())
    f.find(next, 1000, repeats, block)
    reconstruct_matches(block, next, frame, reps, 1024)
    if depth == 0 {
      assert_eq(block.ll[0], 1)
    }
  }
}

///|
test "lazy disables repeats before retained history and does not follow overwritten links" {
  let f = Lazy(
    hash_log=6,
    chain_log=6,
    min_match=4,
    search_log=4,
    depth=2,
    window_log=10,
  )
  let repeats = @seqenc.Repeats()
  repeats.encode(@seqenc.Distance(100U), 1) |> ignore
  repeats.encode(@seqenc.Distance(200U), 1) |> ignore
  let data = FixedArray::makei(32, i => i.to_byte())
  let block = @seqenc.Block()
  f.find(data, 32, repeats, block)
  reconstruct_matches(block, data, [], [200, 100, 1], 1024)
  assert_eq(block.count, 0)
  f.history.data = FixedArray::make(400, b'x')
  f.history.data[228] = b'y'
  f.hash[f.hash_at(300)] = 224
  f.chain[f.slot(224)] = 32
  f.next_update = 300
  f.search(300, 320, false)
  assert_eq((f.match_length, f.match_distance), (4, 76))
}

///|
test "greedy repeat priority preserves literals and immediately swaps repeat two" {
  let f = Lazy(
    hash_log=10,
    chain_log=10,
    min_match=4,
    search_log=3,
    depth=0,
    window_log=10,
  )
  f.history.data = FixedArray::makei(200, i => i.to_byte())
  for i in 0..<4 {
    f.history.data[93 + i] = b"abcd"[i]
  }
  f.history.data[97] = b'z'
  f.history.start = 100
  f.history.end = 100
  f.next_update = 100
  let repeats = @seqenc.Repeats()
  repeats.encode(@seqenc.Distance(4U), 1) |> ignore
  repeats.encode(@seqenc.Distance(8U), 1) |> ignore
  let block = @seqenc.Block()
  let data = FixedArray::makei(41, i => {
    if i == 0 {
      b'!'
    } else {
      b"abcd"[(i - 1) % 4]
    }
  })
  let frame = Array::makei(100, i => f.history.data[i])
  f.find(data, data.length(), repeats, block)
  reconstruct_matches(block, data, frame, [8, 4, 1], 1024)
  assert_eq(block.count, 2)
  assert_eq((block.ll[0], block.ml[0]), (1, 4))
  assert_eq((block.ll[1], block.ml[1]), (0, 36))
  let @seqenc.OffsetValue(first) = block.offsets[0]
  let @seqenc.OffsetValue(second) = block.offsets[1]
  assert_eq(first, 1U)
  assert_eq(second, 1U)
}
