///|
test "reference qualities round trip" {
  let text = b"hello hello hello, reference Brotli static dictionary compression\n"
  for quality in 5..<=9 {
    for n in [0, 1, 2, 3, 20, 64, 1000, 70000] {
      let input = Bytes::makei(n, i => text[i % text.length()])
      let encoded = compress(input, quality~)
      assert_eq(decompress(encoded), input, msg="q\{quality}/\{n}")
    }
  }
}

///|
fn ref_quality_sample(kind : Int32, size : Int32) -> Bytes {
  if kind == 3 {
    let words = [
      b"The ", b"compression ", b"dictionary ", b"representation ", b"the ", b"a ",
      b"window ", b"\n", b"{\"key\": [1, 2]} ", b"\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e ",
      b"\xc3\xa9\xc3\xa0\xc3\xa8 ",
    ]
    let out = Buffer()
    let mut rng = 1951U
    while out.length() < size {
      rng = rng * 1664525U + 1013904223U
      out.write_bytes(words[(rng >> 8).reinterpret_as_int() % words.length()])
    }
    return out.to_bytes()[:size].to_owned()
  }
  let text = b"hello hello hello, reference Brotli static dictionary compression\n"
  let mut state = 1951U
  let data = FixedArray::make(size, b'\x00')
  for i in 0..<size {
    state = state * 1664525U + 1013904223U
    data[i] = if kind == 0 {
      text[i % text.length()]
    } else if kind == 1 {
      (state >> 24).to_byte()
    } else if kind == 4 {
      (((state >> 24) & 31U).reinterpret_as_int() + 32 * ((i / 1024) & 7)).to_byte()
    } else if i % 10000 < 6000 {
      text[i % text.length()]
    } else if i >= 4096 && i % 10000 < 8000 {
      data[i - 4096]
    } else {
      (state >> 24).to_byte()
    }
  }
  Bytes::from_array(data)
}

///|
test "reference qualities: random splits, flushes, dictionaries, reset and memory bounds" {
  for quality in 5..<=9 {
    let input = ref_quality_sample(2, 1400000)
    for window_bits in [10, 22] {
      for hint in [None, Some(1400000L), Some(1L), Some(9223372036854775807L)] {
        let encoder = Encoder(quality~, window_bits~, size_hint?=hint)
        let bound = encoder_memory_bound(
          quality~,
          window_bits~,
          size_hint?=hint,
        )
        assert_true(encoder.memory_usage().to_int64() <= bound)
        let rng = Rng::new(quality.reinterpret_as_uint())
        let encoded = encode_drive(
          encoder,
          input,
          next_in=() => 1 + rng.below(16000),
          next_out=() => 1 + rng.below(2000),
          check=(e, _) => assert_true(e.memory_usage().to_int64() <= bound),
        )
        assert_eq(decompress(encoded), input)
        encoder.reset()
        let again = encode_drive(
          encoder,
          input,
          next_in=() => 17001,
          next_out=() => 3191,
          check=(e, _) => assert_true(e.memory_usage().to_int64() <= bound),
        )
        assert_eq(again, encoded)
      }
    }
    let dictionary = Dictionary(ref_quality_sample(3, 60000))
    let data = ref_quality_sample(3, 40000)
    for window_bits in [10, 22] {
      let encoder = Encoder(quality~, window_bits~, dictionary~)
      let bound = encoder_memory_bound(quality~, window_bits~)
      let rng = Rng::new(100U)
      let encoded = encode_drive(
        encoder,
        data,
        next_in=() => 4000,
        next_out=() => 1 + rng.below(300),
        flush=_ => true,
        check=(e, _) => assert_true(e.memory_usage().to_int64() <= bound),
      )
      assert_eq(decompress(encoded, dictionary~), data)
    }
  }
}

///|
test "reference qualities: clamping and quality four ignores size hint" {
  let input = ref_quality_sample(2, 100000)
  let original = compress(input)
  for quality in [-2147483648, 0, 1, 2, 3, 4] {
    assert_eq(compress(input, quality~), original)
    let baseline = encode_drive(Encoder(quality~), input, next_in=() => 1231, next_out=() => {
      997
    })
    for hint in [-1L, 0L, 100000L, 9223372036854775807L] {
      let encoded = encode_drive(
        Encoder(quality~, size_hint=hint),
        input,
        next_in=() => 7777,
        next_out=() => 103,
        check=(e, _) => {
          assert_true(
            e.memory_usage().to_int64() <=
            encoder_memory_bound(quality~, size_hint=hint),
          )
        },
      )
      assert_eq(encoded, baseline)
      assert_eq(
        encoder_memory_bound(quality~, size_hint=hint),
        encoder_memory_bound(),
      )
    }
  }
  assert_eq(compress(input, quality=2147483647), compress(input, quality=11))
  for quality in [10, 11] {
    let encoded = encode_drive(
      Encoder(quality~, size_hint=input.length().to_int64()),
      input,
      next_in=() => 1231,
      next_out=() => 997,
      check=(e, _) => {
        assert_true(
          e.memory_usage().to_int64() <=
          encoder_memory_bound(quality~, size_hint=input.length().to_int64()),
        )
      },
    )
    assert_eq(encoded, compress(input, quality~))
  }
}

///|
test "reference helpers: position wraps, capped distances and ring-edge matches" {
  for n in 0..<256 {
    let expected = if n < 2 { 0.0 } else { @math.log2(n.to_double()) }
    assert_true((ref_small_log(n) - expected).abs() < 0.000001)
  }
  for
    (pos, expected) in [
      (0L, 0U),
      (3221225471L, 0xbfffffffU),
      (3221225472L, 0x40000000U),
      (4294967296L, 0x80000000U),
      (5368709120L, 0x40000000U),
    ] {
    assert_eq(ref_wrap(pos), expected)
  }
  for
    (quality, window_bits, hint) in [
      (5, 10, 0L),
      (9, 10, 0L),
      (5, 22, 0L),
      (6, 22, 1048576L),
      (7, 17, 0L),
      (9, 22, 1048576L),
    ] {
    for flush in [false, true] {
      let encoder = Encoder(quality~, window_bits~, size_hint=hint)
      let hasher = RefHasher::new(quality, window_bits, hint)
      let memory = hasher.memory_usage()
      let long_hash = hasher.long_hash
      hasher.dict_lookups = 1024L
      hasher.dict_matches = 3L
      encoder.ref_hasher = Some(hasher)
      encoder.data = FixedArray::make(512, b'\x00')
      encoder.data_len = 256
      encoder.block_start = 128
      encoder.ref_processed = 128
      encoder.ref_offset = 3221225472L - 192L
      // A changed hint must not reselect an already configured hasher.
      encoder.ref_hint = 1048576L
      encoder.ref_process(false, flush)
      assert_true(physical_equal(encoder.ref_hasher.unwrap(), hasher))
      assert_false(hasher.prepared)
      assert_eq(hasher.dict_lookups, 1024L)
      assert_eq(hasher.dict_matches, 3L)
      assert_eq(hasher.long_hash, long_hash)
      assert_eq(hasher.memory_usage(), memory)
      // Poison metadata after the wrap, then process an empty flush so no
      // stitching or parsing can obscure which tables Prepare resets.
      hasher.addresses.fill(1U)
      hasher.heads.fill(17)
      hasher.tiny.fill(b'\xff')
      hasher.free.fill(9)
      hasher.counts.fill(7)
      hasher.buckets.fill(0x12345678U)
      hasher.tags.fill(b'\x55')
      hasher.deltas.fill(23)
      hasher.next.fill(42)
      encoder.ref_process(false, true)
      assert_true(physical_equal(encoder.ref_hasher.unwrap(), hasher))
      assert_true(hasher.prepared)
      assert_eq(hasher.dict_lookups, 1024L)
      assert_eq(hasher.dict_matches, 3L)
      assert_true(hasher.dict_matches < hasher.dict_lookups >> 7)
      assert_true(hasher.addresses.all(x => x == 0xccccccccU))
      assert_true(hasher.heads.all(x => x == 0))
      assert_true(hasher.tiny.all(x => x == b'\x00'))
      assert_true(hasher.free.all(x => x == 0))
      let empty_count : UInt16 = if hasher.tagged { 65535 } else { 0 }
      assert_true(hasher.counts.all(x => x == empty_count))
      assert_true(hasher.buckets.all(x => x == 0x12345678U))
      assert_true(hasher.tags.all(x => x == b'\x55'))
      assert_true(hasher.deltas.all(x => x == 23))
      assert_true(hasher.next.all(x => x == 42))
      assert_eq(hasher.memory_usage(), memory)
      encoder.reset()
      assert_true(encoder.ref_hasher is None)
    }
  }
  let hasher = RefHasher::new(7, 17, 0L)
  let data = FixedArray::make(64, b'\x00')
  let cache : FixedArray[Int32] = [
    4, 11, 15, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  ]
  ref_prepare_distances(cache)
  hasher.store(data, 12, hasher.ring_mask - 7U)
  let found = hasher.find(data, 16, hasher.ring_mask - 3U, 40, 16, 16, cache)
  assert_eq(found.length, 24)
  assert_eq(found.distance, 4)
  let word = b"dictionary"
  let data = FixedArray::makei(40, i => {
    if i < word.length() {
      word[i]
    } else {
      b'\x00'
    }
  })
  let found = RefMatch::new()
  hasher.static_match(data, 0, word.length(), MAX_CODED_DISTANCE, found)
  assert_eq(found.length, 0)
  let e = Encoder(quality=5)
  let output = FixedArray::make(10, b'\x00')
  assert_eq(e.step_into(b"", output, action=Finish), Done)
  assert_eq(e.step_into(b"ignored", output, action=Continue), Done)
  assert_eq(e.last_consumed(), 0)
  assert_eq(e.last_produced(), 0)
}

///|
test "reference splitter emits an explicit type after revisiting an older histogram" {
  let split = RefSplit::new(256, 1, 512, 400.0)
  for base in [0, 64, 0, 128] {
    for i in 0..<512 {
      split.add(base + i % 16)
    }
  }
  split.finish()
  assert_eq(split.types, [0, 1, 0, 2])
  let w = @bits.BitPacker()
  let writer = RefBlockWriter::header(split, w)
  assert_true(writer.type_code.depths[4] > 0)
}

///|
test "reference histogram smoothing keeps the lower threshold inclusive" {
  // BrotliOptimizeHuffmanCountsForRle in the pinned entropy_encode.c.
  // At index 19 the fixed-point difference is exactly -1240: the C
  // unsigned interval test keeps it in the stride, yielding 12 everywhere.
  let counts = FixedArray::makei(64, i => {
    if i < 18 {
      if i % 2 == 0 {
        14
      } else {
        16
      }
    } else if i == 18 {
      12
    } else if i % 2 == 0 {
      11
    } else {
      10
    }
  })
  ref_optimize_counts(counts)
  assert_eq(counts, FixedArray::make(64, 12))
}
