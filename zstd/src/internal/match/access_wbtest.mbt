///|
/// Independent checked transcription of the original ZSTD_hash4..8 code.
fn reference_hash(
  data : FixedArray[Byte],
  p : Int32,
  width : Int32,
  log : Int32,
) -> Int32 {
  let mut word = 0UL
  for i in 0..<width {
    word = word | (data[p + i].to_uint64() << (8 * i))
  }
  if width == 4 {
    ((word.to_uint() * 2654435761U) >> (32 - log)).reinterpret_as_int()
  } else {
    let prime = match width {
      5 => 889523592379UL
      6 => 227718039650203UL
      7 => 58295818150454627UL
      _ => 0xcf1bbcdcb7a56463UL
    }
    (((word << (64 - width * 8)) * prime) >> (64 - log)).to_int()
  }
}

///|
test "wide hashes preserve every width at every alignment and valid tail" {
  let mut seed = 8878U
  let data = FixedArray::makei(513, _ => {
    seed = seed * 1664525 + 1013904223
    (seed >> 24).to_byte()
  })
  for width in 4..<=7 {
    let f = Fast(hash_log=8, min_match=width, target_length=0, window_log=10)
    let d = Dfast(hash_log=8, chain_log=7, min_match=width, window_log=10)
    let l = Lazy(
      hash_log=8,
      chain_log=7,
      min_match=width,
      search_log=2,
      depth=2,
      window_log=10,
    )
    f.history.data = data
    d.history.data = data
    l.history.data = data
    for p in 0..<=(data.length() - 8) {
      assert_eq(f.hash_at(p), reference_hash(data, p, width, 8))
      assert_eq(d.short_hash(p), reference_hash(data, p, width, 7))
      assert_eq(d.long_hash(p), reference_hash(data, p, 8, 8))
      assert_eq(l.hash_at(p), reference_hash(data, p, width.min(6), 8))
    }
  }
}

///|
#cfg(any(target="native", target="wasm"))
test "hash8 uses the reference multiplier" {
  assert_eq(hash_prime(8), 0xcf1bbcdcb7a56463UL)
}

///|
test "match length at every mismatch alignment and exact data end" {
  for alignment in 0..<16 {
    for len in 0..<=65 {
      // Allocate exactly through end so spare capacity cannot hide overreads.
      let p = 96 + alignment
      let end = p + len
      let data = FixedArray::makei(end, i => (i % 7).to_byte())
      let q = p - 70
      assert_eq(match_length(data, p, q, end), len)
      for mismatch in 0..<len {
        let old = data[p + mismatch]
        data[p + mismatch] = old ^ b'\xff'
        assert_eq(match_length(data, p, q, end), mismatch)
        data[p + mismatch] = old
      }
    }
  }
}

///|
test "all finders invalidate evicted replays and retain surviving ranges" {
  for kind in 0..<3 {
    for offset in [0, 100] {
      let f = Fast(hash_log=12, min_match=4, target_length=0, window_log=10)
      let d = Dfast(hash_log=12, chain_log=12, min_match=4, window_log=10)
      let l = Lazy(
        hash_log=12,
        chain_log=10,
        min_match=4,
        search_log=4,
        depth=2,
        window_log=10,
      )
      let repeats = @seqenc.Repeats()
      let block = @seqenc.Block()
      let frame : Array[Byte] = []
      let reps : FixedArray[Int32] = [1, 4, 8]
      let mut seed = 8878U
      let original = FixedArray::makei(1024, _ => {
        seed = seed * 1664525 + 1013904223
        (seed >> 24).to_byte()
      })
      let unrelated = FixedArray::makei(64, _ => {
        seed = seed * 1664525 + 1013904223
        (seed >> 24).to_byte()
      })
      let replay = FixedArray::makei(64, i => original[offset + i])
      for data in [original, unrelated, replay] {
        match kind {
          0 => f.find(data, data.length(), repeats, block)
          1 => d.find(data, data.length(), repeats, block)
          _ => l.find(data, data.length(), repeats, block)
        }
        reconstruct_matches(block, data, frame, reps, 1024)
        repeats.copy_from(block.repeats)
      }
      if offset == 0 {
        assert_eq(block.count, 0)
      } else {
        assert_true(block.count > 0)
      }
    }
  }
}
