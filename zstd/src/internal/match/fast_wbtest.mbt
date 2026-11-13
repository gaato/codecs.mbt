///|
test "fast history wraps within the window and resets before another frame" {
  let finder = Fast(hash_log=6, min_match=4, target_length=2, window_log=10)
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
    assert_eq(finder.memory_usage(), finder.data.length() + 4 * 64 + 12)
  }
  assert_true(matched > 30)
  finder.reset()
  repeats.reset()
  finder.find(FixedArray::make(100, b'x'), 100, repeats, block)
  assert_true(block.ll[0] > 0)
  assert_true(finder.history == 100)
}

///|
test "fast permits the exact window distance and refuses older hash candidates" {
  let finder = Fast(hash_log=10, min_match=4, target_length=0, window_log=10)
  let block = @seqenc.Block()
  let repeats = @seqenc.Repeats()
  let mut seed = 8878U
  let data = FixedArray::makei(1024, _ => {
    seed = seed * 1664525 + 1013904223
    (seed >> 24).to_byte()
  })
  finder.find(data, 1024, repeats, block)
  finder.hash.fill(-1)
  finder.hash[finder.hash_at(0)] = 0
  let next = FixedArray::makei(64, i => data[i])
  finder.find(next, 64, repeats, block)
  assert_true(block.count > 0)
  let @seqenc.Distance(d) = repeats.resolve(block.offsets[0], block.ll[0])
  assert_eq(d, 1024U)
  // The eligibility test independently refuses too old and future indices.
  assert_eq(finder.length(1025, 0, 1026), 0)
  assert_eq(finder.length(10, 10, 11), 0)
}
