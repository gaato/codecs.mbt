///|
test "low qualities streaming, flush, dictionary, reset and memory bounds" {
  for quality in 0..<=3 {
    assert_eq(
      encoder_memory_bound(quality~, window_bits=22),
      [5302407L, 6350983L, 75326664L, 75210808L][quality],
    )
    for window_bits in [10, 24] {
      let input = ref_quality_sample(2, low_test_size())
      let expected = compress(input, quality~, window_bits~)
      for hint in [None, Some(input.length().to_int64()), Some(1L)] {
        let encoder = Encoder(quality~, window_bits~, size_hint?=hint)
        let bound = encoder_memory_bound(
          quality~,
          window_bits~,
          size_hint?=hint,
        )
        let rng = Rng::new(131U)
        let encoded = encode_drive(
          encoder,
          input,
          next_in=() => 1 + rng.below(17000),
          next_out=() => 1 + rng.below(1000),
          check=(e, _) => assert_true(e.memory_usage().to_int64() <= bound),
        )
        assert_eq(encoded, expected)
        assert_eq(decompress(encoded), input)
        encoder.reset()
        assert_true(encoder.arena is None)
        assert_eq(
          encode_drive(
            encoder,
            b"reset dictionary compression",
            next_in=() => 3,
            next_out=() => 1,
          ),
          compress(b"reset dictionary compression", quality~, window_bits~),
        )
      }
      let dictionary = Dictionary(ref_quality_sample(3, 10000))
      let data = ref_quality_sample(3, 25000)
      let encoder = Encoder(quality~, window_bits~, dictionary~)
      let bound = encoder_memory_bound(quality~, window_bits~)
      let encoded = encode_drive(
        encoder,
        data,
        next_in=() => 1000,
        next_out=() => 17,
        flush=_ => true,
        check=(e, _) => assert_true(e.memory_usage().to_int64() <= bound),
      )
      assert_eq(decompress(encoded, dictionary~), data)
      assert_true(
        encoded.length().to_int64() <=
        compress_bound(data.length().to_int64(), quality~, window_bits~) +
        7L * 25L,
      )
      if quality <= 1 || quality == 3 {
        assert_eq(
          compress(data, quality~, window_bits~, dictionary~),
          compress(data, quality~, window_bits~),
        )
      }
    }
  }
}

///|
#cfg(target="native")
test "low compressed size bounds account for small-window fragments" {
  for quality in 0..<=3 {
    for window_bits in [10, 16, 22, 24] {
      for kind in [0, 1, 2] {
        let data = ref_quality_sample(kind, 65536)
        let encoded = compress(data, quality~, window_bits~)
        assert_true(
          encoded.length().to_int64() <=
          compress_bound(data.length().to_int64(), quality~, window_bits~),
        )
      }
      let data = ref_quality_sample(1, 4000)
      let flushed = encode_drive(
        Encoder(quality~, window_bits~),
        data,
        next_in=() => 1000,
        next_out=() => 97,
        flush=_ => true,
      )
      assert_true(
        flushed.length().to_int64() <=
        compress_bound(data.length().to_int64(), quality~, window_bits~) +
        7L * 4L,
      )
      assert_eq(decompress(flushed), data)
    }
  }
  assert_eq(
    compress(ref_quality_sample(1, 65536), quality=0, window_bits=10).length(),
    65729,
  )
}

///|
test "quick hasher wrap prepares tables while retaining dictionary counters" {
  for quality in [2, 3] {
    let e = Encoder(quality~, window_bits=10)
    e.data = FixedArray::make(512, b'\x00')
    e.data_len = 256
    e.block_start = 128
    e.ref_processed = 128
    e.ref_offset = 3221225472L - 192L
    let h = QuickHasher::new(quality)
    h.lookups = 1000000L
    h.matches = 7L
    e.low_arena().quick = Some(h)
    e.ref_process(false, false)
    assert_true(physical_equal(e.low_arena().quick.unwrap(), h))
    assert_false(h.prepared)
    let lookups = h.lookups
    let matches = h.matches
    assert_true(lookups >= 1000000L)
    h.buckets.fill(7U)
    h.prepare()
    assert_true(h.buckets.all(x => x == 0U))
    assert_eq(h.lookups, lookups)
    assert_eq(h.matches, matches)
    assert_eq(h.sweep, if quality == 2 { 1 } else { 2 })
  }
}

///|
test "fast Huffman codes handle empty, small and skewed alphabets" {
  let empty = low_fast_code(FixedArray::make(256, 0))
  assert_true(empty.depths.all(x => x == 0))
  let hist = FixedArray::make(256, 0)
  let mut a = 1
  let mut b = 1
  for i in 0..<24 {
    hist[i] = a
    let c = a + b
    a = b
    b = c
  }
  let code = low_fast_code(hist)
  let mut kraft = 0
  for i in 0..<24 {
    assert_true(code.depths[i] > 0 && code.depths[i] <= 14)
    kraft += 1 << (14 - code.depths[i])
  }
  assert_eq(kraft, 1 << 14)
  for quality in [0, 1] {
    for alphabet in 1..<=8 {
      let data = Bytes::makei(1000, i => (i % alphabet).to_byte())
      assert_eq(decompress(compress(data, quality~)), data)
    }
  }
}

///|
#cfg(target="native")
test "low qualities retain distant fragment and window matches" {
  let data = ref_quality_sample(5, 300000)
  for quality in 0..<=3 {
    let encoded = compress(data, quality~)
    assert_eq(decompress(encoded), data)
    assert_true(encoded.length() < data.length())
  }
  for quality in [2, 3] {
    let data = ref_quality_sample(0, 1100000)
    assert_eq(decompress(compress(data, quality~)), data)
  }
}

///|
#cfg(target="native")
fn low_test_size() -> Int32 {
  550001
}

///|
#cfg(not(target="native"))
fn low_test_size() -> Int32 {
  35001
}

///|
test "low qualities empty and repeated flushes keep a decodable stream" {
  for quality in 0..<=3 {
    let e = Encoder(quality~, window_bits=10)
    let out = FixedArray::make(64, b'\x00')
    let stream = Buffer()
    for _ in 0..<2 {
      assert_eq(e.step_into(b"", out, action=Flush), NeedMoreInput)
      stream.write_bytes(Bytes::from_array(out[:e.last_produced()]))
    }
    stream.write_bytes(
      encode_drive(e, b"abc", next_in=() => 1, next_out=() => 1),
    )
    assert_eq(decompress(stream.to_bytes()), b"abc")
  }
}

///|
test "quick shallow dictionary scores exact words, cutoffs and distance limits" {
  let h = QuickHasher::new(2)
  let mut key = 0
  while h.lengths[key].to_int() < 8 {
    key += 2
  }
  let length = h.lengths[key].to_int()
  let word = h.words[key].to_int()
  let offset = dictionary_offsets[length] + length * word
  let data = FixedArray::makei(64, i => {
    if i < length {
      dictionary[offset + i]
    } else {
      b'\x00'
    }
  })
  let exact = RefMatch::new()
  h.dictionary(data, 0, length, 0, exact)
  assert_eq(exact.length, length)
  assert_eq(exact.distance, word + 1)
  assert_eq(h.matches, 1L)
  data[length - 1] = (data[length - 1].to_int() ^ 255).to_byte()
  let cut = RefMatch::new()
  h.dictionary(data, 0, length, 0, cut)
  assert_eq(cut.length, length - 1)
  assert_eq(cut.delta, 1)
  let capped = RefMatch::new()
  h.dictionary(data, 0, length, MAX_CODED_DISTANCE, capped)
  assert_eq(capped.length, 0)
}
