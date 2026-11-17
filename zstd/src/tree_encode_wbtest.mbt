///|
test "new tree levels roundtrip and preserve all input and output splits" {
  let rng = Rng::new(71322)
  let inputs = [
    b"",
    b"x",
    Bytes::make(257, b'a'),
    sample_text(rng, 256),
    sample_random(rng, 257),
  ]
  for level in 13..<=22 {
    for input in inputs {
      let whole = compress(input, level~)
      assert_eq(
        decompress(whole),
        input,
        msg="level \{level}, size \{input.length()}",
      )
      // Every level round-trips. Repeat expensive byte-wise splits only at
      // representative levels; the same parsers implement the other rows.
      if ![13, 16, 19, 22].contains(level) {
        continue
      }
      for (chunk, room) in [(1, 31), (113, 1), (4096, 997)] {
        let encoder = Encoder(level~, content_size=input.length().to_int64())
        let actual = encode_drive(
          encoder,
          input,
          next_in=() => chunk,
          next_out=() => room,
          check=check_encoder_bounds,
        )
        assert_eq(
          actual,
          whole,
          msg="split level \{level}, size \{input.length()}",
        )
        assert_true(
          encoder.memory_usage().to_int64() <=
          encoder_memory_bound(level~, content_size=input.length().to_int64()),
        )
        encoder.reset()
        assert_eq(
          encode_drive(encoder, input, next_in=() => 73, next_out=() => 1031),
          whole,
        )
      }
    }
  }
  // A known source over 256 KiB selects the large-input rows (DUBT, btopt,
  // btultra2) and crosses two block edges. Repeating 512 bytes keeps the parse
  // work small while retaining matches and statistics across those edges.
  let input = sample_text(rng, 512).repeat(528)
  for level in [13, 16, 19, 22] {
    let whole = compress(input, level~)
    assert_eq(decompress(whole), input)
    let split = encode_drive(
      Encoder(level~, content_size=input.length().to_int64()),
      input,
      next_in=() => 4093,
      next_out=() => 16387,
      check=check_encoder_bounds,
    )
    assert_eq(split, whole)
  }
}

///|
test "tree encoder memory bounds cover every new level without allocating large tables" {
  let rows = [
    for level in 13..<=22 => {
      "\{level}: \{encoder_memory_bound(level~)} / \{encoder_memory_bound(level~, content_size=16384)}"
    }
  ]
  inspect(
    rows.join("\n"),
    content=(
      #|13: 44071872 / 2507316
      #|14: 60849088 / 2572852
      #|15: 77626304 / 2572852
      #|16: 44270132 / 2572852
      #|17: 69435956 / 2572852
      #|18: 69960244 / 2572852
      #|19: 103514676 / 2572852
      #|20: 237732404 / 2572852
      #|21: 472613428 / 2572852
      #|22: 942375476 / 2572852
    ),
  )
}

///|
test "tree encoders preserve dictionary repeats and split independence" {
  let raw = Dictionary::raw(dict_bytes("raw"))
  let trained = Dictionary::parse(dict_bytes("trained"))
  let inputs = dict_inputs()
  let samples = [b"", inputs[inputs.length() - 1].1[:256].to_owned()]
  for level in 13..<=22 {
    for dictionary in [raw, trained] {
      for input in samples {
        let whole = compress(input, level~, dictionary~)
        assert_eq(decompress(whole, dictionary~), input)
        if !input.is_empty() && ![13, 16, 19, 22].contains(level) {
          continue
        }
        let encoder = Encoder(
          level~,
          dictionary~,
          content_size=input.length().to_int64(),
        )
        let split = encode_drive(
          encoder,
          input,
          next_in=() => 73,
          next_out=() => 113,
          check=check_encoder_bounds,
        )
        assert_eq(split, whole)
        encoder.reset()
        assert_eq(
          encode_drive(encoder, input, next_in=() => 1, next_out=() => 997),
          whole,
        )
      }
    }
  }
}

///|
test "new tree levels append reproducible SHA-256 pins" {
  let rng = Rng::new(1951)
  let input = sample_text(rng, 256) +
    sample_random(rng, 32) +
    sample_text(rng, 128)
  let pins = [
    for level in 13..<=22 => @checksum.sha256(compress(input, level~))
  ]
  inspect(
    pins.join("\n"),
    content=(
      #|40edceabb38c4633eff84bb797f37a686ce7e48bc93694e1534dbffebb56cdfb
      #|40edceabb38c4633eff84bb797f37a686ce7e48bc93694e1534dbffebb56cdfb
      #|40edceabb38c4633eff84bb797f37a686ce7e48bc93694e1534dbffebb56cdfb
      #|40edceabb38c4633eff84bb797f37a686ce7e48bc93694e1534dbffebb56cdfb
      #|40edceabb38c4633eff84bb797f37a686ce7e48bc93694e1534dbffebb56cdfb
      #|40edceabb38c4633eff84bb797f37a686ce7e48bc93694e1534dbffebb56cdfb
      #|40edceabb38c4633eff84bb797f37a686ce7e48bc93694e1534dbffebb56cdfb
      #|40edceabb38c4633eff84bb797f37a686ce7e48bc93694e1534dbffebb56cdfb
      #|40edceabb38c4633eff84bb797f37a686ce7e48bc93694e1534dbffebb56cdfb
      #|40edceabb38c4633eff84bb797f37a686ce7e48bc93694e1534dbffebb56cdfb
    ),
  )
}

///|
test "DUBT and btopt have pins at their smallest new-level size classes" {
  // Level 13 changes from btultra to btopt just above 16 KiB, and from
  // btopt to DUBT just above 256 KiB. Pin both routes without a large
  // nonrepeating source that would make the optimal parse expensive.
  assert_true(encoder_params(13, Some(16384)).strategy is Btultra)
  assert_true(encoder_params(13, Some(16385)).strategy is Btopt)
  assert_true(encoder_params(13, Some(262144)).strategy is Btopt)
  assert_true(encoder_params(13, Some(262145)).strategy is Btlazy2)
  let prefix = sample_text(Rng::new(1951), 1024)
  let pins = []
  for (name, n) in [("DUBT", 262145), ("btopt", 16385)] {
    let input = prefix.repeat((n + prefix.length() - 1) / prefix.length())[:n].to_owned()
    let frame = compress(input, level=13)
    assert_eq(decompress(frame), input)
    pins.push("\{name}: \{@checksum.sha256(frame)}")
  }
  inspect(
    pins.join("\n"),
    content=(
      #|DUBT: 07bc6176c06093b81c1c24c005fcb22359dae9d307cdf88f7a752947cfa52a3d
      #|btopt: 203d74dfe0d43b41c87dfe6695c085d8eede19efc8d3c7fdc6409875dab37846
    ),
  )
}

///|
test "new tree rows keep adjustment and a 27-bit interoperable window" {
  inspect(complete_row(params_for(13, None)), content="22/22/22/4/5/32/Btlazy2")
  inspect(
    complete_row(params_for(22, None)),
    content="27/27/25/9/3/999/Btultra2",
  )
  inspect(
    complete_row(params_for(13, Some(262144))),
    content="18/18/19/4/4/16/Btopt",
  )
  inspect(
    complete_row(params_for(13, Some(131072))),
    content="17/18/17/3/4/12/Btopt",
  )
  inspect(
    complete_row(params_for(13, Some(16384))),
    content="14/15/14/5/3/32/Btultra",
  )
  for level in 13..<=22 {
    for
      size in [
        None,
        Some(0L),
        Some(65L),
        Some(16384L),
        Some(131072L),
        Some(262144L),
        Some(262145L),
      ] {
      let p = params_for(level, size)
      assert_eq(complete_row(encoder_params(level, size)), complete_row(p))
      let raw = params_for(level, None)
      assert_true(p.window_log <= raw.window_log)
      assert_true(p.chain_log <= raw.chain_log)
      assert_true(p.hash_log <= raw.hash_log)
      assert_true(
        encoder_memory_bound(level~, content_size?=size) <=
        encoder_memory_bound(level~),
      )
    }
  }
  // Exercise the largest advertised window without allocating a level-22
  // unknown-size tree (~640 MiB just for its two position tables).
  let out = @bits.BitPacker()
  write_frame_header(out, None, 27, false, false)
  out.write(24, 1) // Empty final raw block.
  let bytes = FixedArray::make(out.pending(), b'\x00')
  out.drain_into(bytes, 0) |> ignore
  let frame = Bytes::from_array(bytes[:])
  assert_eq(frame_header_of(frame).window_size, 1UL << 27)
  assert_eq(Decoder().max_window_bits, 27)
  assert_eq(decompress(frame), b"")
}
