///|
// A small window keeps split-input lifecycle checks cheap on all backends;
// the native matrix below also exercises large inputs and full forests.
test "HQ small split streams preserve bytes across hints and reset" {
  let input = ref_quality_sample(3, 4096)
  let reset_input = b"reset dictionary compression"
  for quality in [10, 11] {
    let expected = compress(input, quality~, window_bits=10)
    let reset_expected = compress(reset_input, quality~, window_bits=10)
    for hint in [None, Some(4096L), Some(1L), Some(9223372036854775807L)] {
      let e = Encoder(quality~, window_bits=10, size_hint?=hint)
      let bound = encoder_memory_bound(
        quality~,
        window_bits=10,
        size_hint?=hint,
      )
      let encoded = encode_drive(e, input, next_in=() => 17, next_out=() => 7, check=(
        e,
        _,
      ) => assert_true(e.memory_usage().to_int64() <= bound))
      assert_eq(encoded, expected)
      assert_eq(decompress(encoded), input)
      e.reset()
      assert_true(e.hq_tree is None)
      assert_eq(
        encode_drive(e, reset_input, next_in=() => 3, next_out=() => 1),
        reset_expected,
      )
    }
    let dictionary = Dictionary(input)
    let e = Encoder(quality~, window_bits=10, dictionary~)
    let bound = encoder_memory_bound(quality~, window_bits=10)
    let encoded = encode_drive(
      e,
      input,
      next_in=() => 127,
      next_out=() => 7,
      flush=_ => true,
      check=(e, _) => assert_true(e.memory_usage().to_int64() <= bound),
    )
    assert_eq(decompress(encoded, dictionary~), input)
  }
}

///|
// The full streaming/hint matrix belongs on native; small pinned vectors
// and the split/cluster observer below exercise HQ on every target.
#cfg(target="native")
test "HQ streaming splits, wrong hints, flushes, dictionaries and reset stay bounded" {
  for quality in [10, 11] {
    let input = ref_quality_sample(2, 70000)
    for window_bits in [10, 24] {
      let expected = compress(input, quality~, window_bits~)
      for hint in [None, Some(70000L), Some(1L), Some(9223372036854775807L)] {
        let e = Encoder(quality~, window_bits~, size_hint?=hint)
        let bound = encoder_memory_bound(
          quality~,
          window_bits~,
          size_hint?=hint,
        )
        let rng = Rng::new(131U)
        let encoded = encode_drive(
          e,
          input,
          next_in=() => 1 + rng.below(17000),
          next_out=() => 1 + rng.below(1000),
          check=(e, _) => assert_true(e.memory_usage().to_int64() <= bound),
        )
        assert_eq(encoded, expected)
        assert_eq(decompress(encoded), input)
        e.reset()
        assert_true(e.hq_tree is None)
        assert_eq(
          encode_drive(e, b"reset dictionary compression", next_in=() => 3, next_out=() => {
            1
          }),
          compress(b"reset dictionary compression", quality~, window_bits~),
        )
      }
      let dictionary = Dictionary(ref_quality_sample(3, 10000))
      let input = ref_quality_sample(3, 10000)
      let e = Encoder(quality~, window_bits~, dictionary~)
      let bound = encoder_memory_bound(quality~, window_bits~)
      let encoded = encode_drive(
        e,
        input,
        next_in=() => 1000,
        next_out=() => 17,
        flush=_ => true,
        check=(e, _) => assert_true(e.memory_usage().to_int64() <= bound),
      )
      assert_eq(decompress(encoded, dictionary~), input)
    }
  }
}

///|
test "H10 tree allocation, preparation and position wrap retain their layout" {
  for bits in [10, 16] {
    let tree = HqTree::new(bits, 7, false)
    assert_eq(tree.memory_usage().to_int64(), hq_tree_bound(bits))
    assert_eq(tree.forest.length(), 2 << bits)
    tree.buckets.fill(7U)
    tree.forest.fill(19U)
    tree.prepared = false
    tree.prepare()
    assert_true(tree.buckets.all(x => x == tree.invalid))
    assert_true(tree.forest.all(x => x == 19U))
    assert_eq(HqTree::new(bits, 7, true).forest.length(), 14)
  }
  assert_eq(HqTree::new(24, 7, true).forest.length(), 14)
  for quality in [10, 11] {
    let e = Encoder(quality~, window_bits=10, size_hint=1L)
    e.data = FixedArray::make(512, b'\x00')
    e.data_len = 256
    e.block_start = 128
    e.ref_processed = 128
    e.ref_offset = 3221225472L - 192L
    let tree = HqTree::new(10, 128, false)
    e.hq_tree = Some(tree)
    e.ref_process(false, false)
    assert_true(physical_equal(e.hq_tree.unwrap(), tree))
    assert_false(tree.prepared)
    tree.buckets.fill(7U)
    tree.prepare()
    assert_true(tree.buckets.all(x => x == tree.invalid))
    assert_eq(tree.memory_usage().to_int64(), hq_tree_bound(10))
    e.reset()
    assert_true(e.hq_tree is None)
    assert_eq(
      encoder_memory_bound(quality~, size_hint=1L),
      encoder_memory_bound(quality~, size_hint=1073741824L),
    )
  }
}

///|
// Full window-24 forests exercise allocation growth, not target arithmetic.
#cfg(target="native")
test "H10 full window-24 forests retain their layout and grow within the bound" {
  let tree = HqTree::new(24, 7, false)
  assert_eq(tree.memory_usage().to_int64(), hq_tree_bound(24))
  assert_eq(tree.forest.length(), 2 << 24)
  tree.buckets.fill(7U)
  tree.forest.fill(19U)
  tree.prepared = false
  tree.prepare()
  assert_true(tree.buckets.all(x => x == tree.invalid))
  assert_true(tree.forest.all(x => x == 19U))
  for quality in [10, 11] {
    let large = Encoder(quality~, window_bits=24, size_hint=1L)
    let large_bound = encoder_memory_bound(
      quality~,
      window_bits=24,
      size_hint=1L,
    )
    let input = Bytes::make(270000, b'A')
    let encoded = encode_drive(
      large,
      input,
      next_in=() => 17001,
      next_out=() => 127,
      check=(e, _) => assert_true(e.memory_usage().to_int64() <= large_bound),
    )
    assert_eq(decompress(encoded), input)
    assert_eq(large.hq_tree.unwrap().forest.length(), 2 << 24)
    assert_eq(
      large.hq_tree.unwrap().memory_usage().to_int64(),
      hq_tree_bound(24),
    )
  }
}

///|
test "HQ public bounds stay fixed on every target" {
  for quality in [10, 11] {
    assert_eq(encoder_memory_bound(quality~, window_bits=22), 27197068000L)
    assert_eq(encoder_memory_bound(quality~, window_bits=24), 54464238304L)
  }
}

///|
// Allocate the largest parser capacities once; the phase observer below
// checks real parser and coding accounting on all targets with small input.
#cfg(target="native")
test "HQ allocation bounds use packed nodes and capacity ceilings" {
  for quality in [10, 11] {
    for bits in [10, 16, 18, 22, 24] {
      let block = ref_input_block(quality, bits)
      let dp = HqDp::new(block, quality)
      let bytes = 4 *
        (
          dp.lengths.length() +
          dp.distances.length() +
          dp.inserts.length() +
          dp.info.length() +
          dp.model.commands.length() +
          dp.model.distances.length() +
          dp.model.literals.length() +
          dp.model.histogram.length() +
          dp.positions.length() +
          dp.cache.length() +
          dp.costs.length() +
          dp.differences.length() +
          4
        )
      assert_true(bytes.to_int64() <= hq_parse_bound(quality, block.to_int64()))
      assert_true(
        hq_tree_bound(bits) + hq_parse_bound(quality, block.to_int64()) <
        encoder_memory_bound(quality~, window_bits=bits),
      )
    }
  }
}

///|
fn HqPeak::new() -> HqPeak {
  {
    bytes: 0L,
    parser: 0L,
    archive_capacity: 0,
    archive_grows: 0,
    passes: 0,
    second_model: 0L,
    blocks: 0,
    clusters: 0,
    trees_upper: 0L,
  }
}

///|
// The large binary-alphabet corpus forces archive growth. Native retains
// this capacity regression; every target still checks both cost passes.
#cfg(target="native")
test "HQ real parser peaks include archive growth and both cost passes" {
  for quality in [10, 11] {
    let length = if quality == 10 { 32768 } else { 262144 }
    let e = Encoder(quality~, window_bits=18)
    let mut seed = 1951U
    e.data = FixedArray::makei(length + 8, _ => {
      seed = seed * 1664525U + 1013904223U
      (65U + ((seed >> 24) & 1U)).to_byte()
    })
    e.data_len = length
    let peak = HqPeak::new()
    let tree = HqTree::new(18, length, true, peak~)
    e.hq_tree = Some(tree)
    e.hq_parse(tree, quality, 0, length, 0U)
    let dp_bytes = 20L * length.to_int64() + 6408L
    assert_true(!e.ref_commands.unwrap().is_empty())
    if quality == 10 {
      assert_eq(peak.passes, 1)
      assert_eq(peak.parser, dp_bytes + 12L)
    } else {
      assert_eq(peak.passes, 2)
      assert_true(peak.archive_grows > 0)
      assert_true(peak.archive_capacity > 8 * length)
      assert_eq(peak.second_model, 5120L)
      assert_eq(
        peak.parser,
        dp_bytes + 4L * (length + peak.archive_capacity).to_int64() + 5120L,
      )
    }
    assert_true(
      peak.parser <= hq_parse_bound(quality, length.to_int64()),
      msg="q\{quality}: measured parser \{peak.parser} exceeds its bound",
    )
  }
}

///|
fn hq_measure(input : Bytes, quality : Int32, window : Int32) -> HqPeak raise {
  let peak = HqPeak::new()
  let e = Encoder(
    quality~,
    window_bits=window,
    size_hint=input.length().to_int64(),
  )
  let block = ref_input_block(quality, window)
  // Install exactly the tree hq_process would construct for the first block,
  // with the observer attached. A hint never shortens a streaming forest.
  e.hq_tree = Some(
    HqTree::new(
      window,
      input.length().min(block),
      input.length() <= block,
      peak~,
    ),
  )
  let encoded = encode_drive(
    e,
    input,
    next_in=() => input.length().max(1),
    next_out=() => 4096,
    check=(e, _) => peak.bytes = peak.bytes.max(e.memory_usage().to_int64()),
  )
  assert_eq(decompress(encoded), input)
  assert_true(peak.parser <= hq_parse_bound(quality, block.to_int64()))
  // Uninstrumented Huffman/map helpers cannot determine the reported peak.
  assert_true(
    peak.trees_upper <= peak.bytes,
    msg="tree envelope \{peak.trees_upper} exceeds observed peak \{peak.bytes}",
  )
  assert_true(peak.bytes <= encoder_memory_bound(quality~, window_bits=window))
  peak
}

///|
test "HQ phase accounting observes splitting and clustering below the bound" {
  for quality in [10, 11] {
    let peak = hq_measure(ref_quality_sample(4, 8192), quality, 18)
    assert_eq(peak.passes, quality - 9)
    assert_true(peak.blocks > 1)
    assert_true(peak.clusters > 1)
    assert_true(peak.trees_upper > 0L)
  }
}
