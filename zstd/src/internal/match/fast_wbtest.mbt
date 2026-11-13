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

///|
test "fast follows reference paired searches and hash insertion order" {
  let data = FixedArray::make(8192, b'\x00')
  let mut seed = 8878U
  for i in 0..<8192 {
    seed = seed * 1664525 + 1013904223
    data[i] = if i >= 256 && i % 47 < 31 {
      data[i - 193]
    } else {
      ((seed >> 24) % 16).to_byte()
    }
  }
  let rows = []
  for width in [4, 5, 6, 7] {
    for acceleration in [0, 8] {
      let finder = Fast(
        hash_log=6,
        min_match=width,
        target_length=acceleration,
        window_log=14,
      )
      let block = @seqenc.Block()
      let repeats = @seqenc.Repeats()
      finder.find(data, data.length(), repeats, block)
      let mut hash = 14695981039346656037UL
      for i in 0..<block.count {
        let @seqenc.Distance(distance) = repeats.resolve(
          block.offsets[i],
          block.ll[i],
        )
        for
          value in [
            block.ll[i].to_uint64(),
            block.ml[i].to_uint64(),
            distance.to_uint64(),
          ] {
          hash = (hash ^ value) * 1099511628211UL
        }
      }
      rows.push(
        "\{width}/\{acceleration}: \{block.count} \{block.literal_count} \{hash}",
      )
    }
  }
  // Instrumented v1.5.7 ZSTD_compressBlock_fast_noDict_generic with
  // wlog=14,hlog=6,minMatch=width,tlen=acceleration on the data above.
  // Hash every (LL, ML, raw distance), including immediate repeat matches.
  inspect(
    rows.join("\n"),
    content=(
      #|4/0: 172 2938 15773209400949746909
      #|4/8: 167 3198 14087964872031600058
      #|5/0: 169 2949 10804152474017949082
      #|5/8: 170 3129 11810505664092879323
      #|6/0: 170 2939 10877654047666845925
      #|6/8: 167 3198 14087964872031600058
      #|7/0: 167 3011 7132836729279216012
      #|7/8: 170 3129 11810505664092879323
    ),
  )
}

///|
test "fast disables search repeats outside the retained prefix" {
  let repeats = @seqenc.Repeats()
  repeats.resolve(@seqenc.OffsetValue(2003), 1) |> ignore
  repeats.resolve(@seqenc.OffsetValue(3003), 1) |> ignore
  let finder = Fast(hash_log=6, min_match=4, target_length=0, window_log=10)
  let block = @seqenc.Block()
  finder.find(FixedArray::make(128, b'x'), 128, repeats, block)
  assert_true(block.count > 0)
  // The invalid repeats are ignored by search, not rewritten in the
  // committed history. The first match must point into its own literals.
  assert_true(repeats.get(0) == @seqenc.Distance(3000))
  let @seqenc.Distance(distance) = repeats.resolve(
    block.offsets[0],
    block.ll[0],
  )
  assert_true(distance > 0 && distance <= block.ll[0].reinterpret_as_uint())
}
