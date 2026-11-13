///|
test "dfast history wraps within the window and resets before another frame" {
  let finder = Dfast(hash_log=6, min_match=4, chain_log=6, window_log=10)
  let repeats = @seqenc.Repeats()
  let block = @seqenc.Block()
  let mut history : Array[Byte] = []
  let mut total = 0
  let mut matched = 0
  for b in 0..<40 {
    let data = FixedArray::makei(997, i => ((i + b * 997) % 251).to_byte())
    finder.find(data, data.length(), repeats, block)
    let got : Array[Byte] = []
    let mut lit = 0
    let decoded = @seqenc.Repeats()
    decoded.copy_from(repeats)
    for i in 0..<block.count {
      for _ in 0..<block.ll[i] {
        got.push(block.literals[lit])
        lit += 1
      }
      let @seqenc.Distance(d) = decoded.resolve(block.offsets[i], block.ll[i])
      let distance = d.reinterpret_as_int()
      assert_true(
        distance <= 1024 && distance <= history.length() + got.length(),
      )
      for _ in 0..<block.ml[i] {
        let from = history.length() + got.length() - distance
        got.push(
          if from < history.length() {
            history[from]
          } else {
            got[from - history.length()]
          },
        )
      }
      matched += 1
    }
    for i in lit..<block.literal_count {
      got.push(block.literals[i])
    }
    assert_eq(got, Array::makei(data.length(), i => data[i]))
    repeats.copy_from(block.repeats)
    total += data.length()
    history = [..history, ..got]
    if history.length() > 1024 {
      history = history[history.length() - 1024:].to_owned()
    }
    assert_eq(finder.history, total.min(1024))
    assert_true(finder.data.length() <= 1024 + 131072)
    assert_eq(finder.memory_usage(), finder.data.length() + 8 * 64)
  }
  assert_true(matched > 30)
  finder.reset()
  repeats.reset()
  finder.find(FixedArray::make(100, b'x'), 100, repeats, block)
  assert_true(block.ll[0] > 0)
  assert_true(finder.history == 100)
}

///|
test "dfast permits the exact window distance and refuses older hash candidates" {
  let finder = Dfast(hash_log=10, min_match=4, chain_log=10, window_log=10)
  let block = @seqenc.Block()
  let repeats = @seqenc.Repeats()
  let mut seed = 8878U
  let data = FixedArray::makei(1024, _ => {
    seed = seed * 1664525 + 1013904223
    (seed >> 24).to_byte()
  })
  finder.find(data, 1024, repeats, block)
  finder.long.fill(-1)
  finder.long[finder.hash_at(0, 8, 10)] = 0
  let next = FixedArray::makei(64, i => data[i])
  finder.find(next, 64, repeats, block)
  assert_true(block.count > 0)
  let @seqenc.Distance(d) = repeats.resolve(block.offsets[0], block.ll[0])
  assert_eq(d, 1024U)
  // The eligibility test independently refuses too old and future indices.
  assert_eq(finder.length(1025, 0, 1026), 0)
  assert_eq(finder.length(10, 10, 11), 0)
}

///|
test "dfast long table wins over a colliding short match" {
  let finder = Dfast(hash_log=10, chain_log=10, min_match=4, window_log=10)
  let repeats = @seqenc.Repeats()
  let block = @seqenc.Block()
  let mut seed = 123U
  let data = FixedArray::makei(1024, _ => {
    seed = seed * 1664525 + 1013904223
    (seed >> 24).to_byte()
  })
  for i in 0..<4 {
    data[500 + i] = data[i]
  }
  finder.find(data, 1024, repeats, block)
  finder.long.fill(-1)
  finder.short.fill(-1)
  finder.long[finder.hash_at(0, 8, 10)] = 0
  finder.short[finder.hash_at(0, 4, 10)] = 500
  finder.find(FixedArray::makei(64, i => data[i]), 64, repeats, block)
  assert_eq(block.count, 1)
  assert_eq(block.ll[0], 0)
  assert_eq(block.ml[0], 64)
  let @seqenc.Distance(d) = repeats.resolve(block.offsets[0], 0)
  assert_eq(d, 1024U)
}

///|
test "dfast repeat priority and hash widths over short and empty blocks" {
  for width in [4, 5, 6, 7] {
    let finder = Dfast(hash_log=8, chain_log=7, min_match=width, window_log=10)
    let repeats = @seqenc.Repeats()
    let block = @seqenc.Block()
    let data = FixedArray::makei(2000, i => (i % 19).to_byte())
    finder.find(data, 1000, repeats, block)
    repeats.copy_from(block.repeats)
    let next = FixedArray::makei(1000, i => ((i + 1000) % 19).to_byte())
    finder.find(next, 1000, repeats, block)
    // The first recent offset is checked at +1 before either hash match.
    assert_eq(block.ll[0], 1)
    let @seqenc.OffsetValue(v) = block.offsets[0]
    assert_eq(v, 1U)
    finder.find(data, 0, repeats, block)
    assert_eq(block.count, 0)
    finder.find(data, 3, repeats, block)
    assert_eq(block.literal_count, 3)
  }
}

///|
test "dfast ignores repeat offsets before the frame start" {
  let finder = Dfast(hash_log=6, chain_log=6, min_match=4, window_log=10)
  let repeats = @seqenc.Repeats()
  // A writer may retain distances too far back for the finder's retained
  // history. Neither distance is eligible just because it later fits.
  repeats.encode(@seqenc.Distance(100U), 1) |> ignore
  repeats.encode(@seqenc.Distance(200U), 1) |> ignore
  let block = @seqenc.Block()
  let data = FixedArray::makei(32, i => i.to_byte())
  finder.find(data, 32, repeats, block)
  assert_eq(block.count, 0)
  assert_eq(block.literal_count, 32)
}

///|
test "dfast rebased lookups invalidate evicted entries and retain surviving ranges" {
  // Separate replays keep the retained range eligible: placing it after
  // the evicted replay would itself move its distance outside the window.
  for offset in [0, 100] {
    let finder = Dfast(hash_log=12, chain_log=12, min_match=4, window_log=10)
    let repeats = @seqenc.Repeats()
    let block = @seqenc.Block()
    let frame : Array[Byte] = []
    let reps : FixedArray[Int32] = [1, 4, 8]
    let mut seed = 8878U
    let original = FixedArray::makei(1024, _ => {
      seed = seed * 1664525 + 1013904223
      (seed >> 24).to_byte()
    })
    finder.find(original, 1024, repeats, block)
    reconstruct_matches(block, original, frame, reps, 1024)
    repeats.copy_from(block.repeats)
    let old_long = finder.long.copy()
    let old_short = finder.short.copy()
    let unrelated = FixedArray::makei(64, _ => {
      seed = seed * 1664525 + 1013904223
      (seed >> 24).to_byte()
    })
    finder.find(unrelated, 64, repeats, block)
    reconstruct_matches(block, unrelated, frame, reps, 1024)
    repeats.copy_from(block.repeats)
    let mut discarded = 0
    for pair in [(old_long, finder.long, 8), (old_short, finder.short, 4)] {
      let (old, table, width) = pair
      for h in 0..<table.length() {
        if old[h] >= 0 && old[h] < 64 && table[h] == -1 {
          discarded += 1
        }
        if table[h] >= 0 {
          assert_eq(finder.hash_at(table[h], width, 12), h)
          assert_true(table[h] < 1024)
        }
      }
    }
    assert_true(discarded > 0)
    let replay = FixedArray::makei(64, i => original[offset + i])
    finder.find(replay, 64, repeats, block)
    reconstruct_matches(block, replay, frame, reps, 1024)
    if offset == 0 {
      assert_eq(block.count, 0)
    } else {
      assert_true(block.count > 0)
    }
  }
}
