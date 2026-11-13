///|
test "shared history slides only for a whole block and rebases both tables once" {
  let first : FixedArray[Int32] = [-1, 2047, 2048, 2049, 3000]
  let second = first.copy()
  let h = History::new(1024, first, second)
  for _ in 0..<3 {
    assert_eq(h.prepare(1024), 0)
    // Partial caller input cannot cause a slide or change block boundaries.
    for _ in 0..<4 {
      h.append(b"x".repeat(256))
    }
    h.finish_block()
  }
  assert_eq(h.start, 3072)
  assert_eq(h.capacity(), 3072)
  assert_eq(h.prepare(1024), 2048)
  assert_eq(h.start, 1024)
  assert_eq(first, [-1, -1, 0, 1, 952])
  assert_eq(second, first)
  h.append(b"y".repeat(1024))
  assert_eq(h.data[1023], b'x')
  assert_eq(h.data[1024], b'y')
  h.finish_block()
  h.reset()
  assert_eq(h.capacity(), 0)
  assert_eq(h.start, 0)
  assert_eq(h.end, 0)
  assert_true(first.iter().all(p => p == -1))
}

///|
test "all finders replay just above and below repeated physical cuts" {
  for kind in 0..<5 {
    for offset in [2047, 2049] {
      let f = Fast(hash_log=14, min_match=4, target_length=0, window_log=10)
      let d = Dfast(hash_log=14, chain_log=14, min_match=4, window_log=10)
      let l = Lazy(
        hash_log=14,
        chain_log=12,
        min_match=4,
        search_log=4,
        depth=(kind - 2).max(0),
        window_log=10,
      )
      let h = match kind {
        0 => f.history
        1 => d.history
        _ => l.history
      }
      let block = @seqenc.Block()
      let repeats = @seqenc.Repeats()
      let frame : Array[Byte] = []
      let reps : FixedArray[Int32] = [1, 4, 8]
      let mut seed = 8878U
      let mut slides = 0
      for _ in 0..<6 {
        let original = FixedArray::makei(3072, _ => {
          seed = seed * 1664525 + 1013904223
          (seed >> 24).to_byte()
        })
        // Align at the physical capacity so the replay triggers a cut.
        while h.start < 3072 {
          let data = FixedArray::makei(1024, i => original[h.start + i])
          match kind {
            0 => f.find(data, 1024, repeats, block)
            1 => d.find(data, 1024, repeats, block)
            _ => l.find(data, 1024, repeats, block)
          }
          reconstruct_matches(block, data, frame, reps, 1024)
          repeats.copy_from(block.repeats)
        }
        let replay = FixedArray::makei(64, i => original[offset + i])
        let before = h.start
        match kind {
          0 => f.find(replay, 64, repeats, block)
          1 => d.find(replay, 64, repeats, block)
          _ => l.find(replay, 64, repeats, block)
        }
        assert_true(h.start < before)
        slides += 1
        reconstruct_matches(block, replay, frame, reps, 1024)
        if offset == 2047 {
          assert_eq(block.count, 0)
        } else {
          assert_true(block.count > 0)
        }
        repeats.copy_from(block.repeats)
        // Finish the partial physical region without altering the cutter.
        let padding = FixedArray::make(960, b'!')
        match kind {
          0 => f.find(padding, 960, repeats, block)
          1 => d.find(padding, 960, repeats, block)
          _ => l.find(padding, 960, repeats, block)
        }
        reconstruct_matches(block, padding, frame, reps, 1024)
        repeats.copy_from(block.repeats)
      }
      assert_eq(slides, 6)
    }
  }
}
