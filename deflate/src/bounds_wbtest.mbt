///|
/// What `memory_usage` reports, with a dictionary or without
/// (RESOURCE_BOUNDS.md).
const BOUND : Int32 = 46592

///|
/// Checks the limits RESOURCE_BOUNDS.md states, after a step that had `room`
/// bytes of output.
fn check_bounds(d : Decoder, room : Int32) -> Unit raise {
  assert_true(d.last_produced() <= room)
  let dictionary = match d.dictionary {
    Some(bytes) => bytes.length()
    None => 0
  }
  assert_true(dictionary <= WINDOW_SIZE)
  assert_true(d.inflater.kept_bytes() <= 5)
  assert_eq(d.memory_usage(), BOUND)
}

///|
test "output slices and reported memory stay within their bounds" {
  assert_eq(Decoder().memory_usage(), BOUND)
  for v in vectors {
    guard v.size <= 300000 else { continue }
    let (got, _) = @fixtures.drive(
      Decoder(),
      v.input(),
      next_in=() => 1,
      next_out=() => 997,
      check=check_bounds,
    )
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "only the last 32 KiB of a dictionary are kept, by reference" {
  for entry in dictionary_vectors {
    let (v, dictionary) = entry
    let dictionary = @fixtures.decode64(dictionary)
    let decoder = Decoder(dictionary~)
    // A view of the caller's bytes: their last 32 KiB, not a copy.
    let kept = decoder.dictionary.unwrap()
    assert_true(physical_equal(kept.data(), dictionary), msg=v.name)
    assert_eq(kept.start_offset() + kept.length(), dictionary.length())
    assert_eq(kept.length(), dictionary.length().min(WINDOW_SIZE))
    let (got, _) = @fixtures.drive(
      decoder,
      v.input(),
      next_in=() => 333,
      next_out=() => 4096,
      check=check_bounds,
    )
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
    assert_eq(decoder.memory_usage(), BOUND, msg=v.name)
  }
  inspect(
    Decoder(dictionary=Bytes::make(40000, b'd')).memory_usage(),
    content="46592",
  )
}

///|
/// What `Encoder::memory_usage` reports at `level` (RESOURCE_BOUNDS.md).
fn encoder_bound(level : Int32) -> Int32 {
  match level.clamp(min=0, max=9) {
    0 => 131077
    1 => 361948
    2 | 3 | 4 => 542172
    _ => 542516
  }
}

///|
/// The input buffer and the output buffer at `level`: the window, a block
/// and the look-ahead (a block and a byte at level 0); a block's stored size.
fn encoder_buffers(level : Int32) -> (Int32, Int32) {
  match level.clamp(min=0, max=9) {
    0 => (65536, 65541)
    1 | 2 | 3 | 4 => (32768 + 65535 + 6144, 65534 + 258 + 10 + 1)
    _ => (32768 + 65535 + 6144, 65534 + 602 + 10 + 1)
  }
}

///|
test "the encoder reports its bound after every step" {
  let input = @fixtures.sample(10, 150000)
  let dictionary = @fixtures.sample(11, 40000)
  for level in 0..<=9 {
    let bound = encoder_bound(level)
    for encoder in [Encoder(level~), Encoder(level~, dictionary~)] {
      assert_eq(encoder.memory_usage(), bound, msg="level \{level}")
      assert_eq(encoder.deflater.capacities(), encoder_buffers(level))
      let rng = @fixtures.Rng::new(level.reinterpret_as_uint())
      let _ = @fixtures.encode(
        encoder,
        input,
        next_in=() => 1 + rng.below(40000),
        next_out=() => rng.below(3000),
        flush_every=50000,
        check=(e, _) => assert_eq(e.memory_usage(), bound),
      )
      encoder.reset()
      assert_eq(encoder.memory_usage(), bound)
    }
  }
}

///|
test "the encoder holds at most its input buffer and a block's output" {
  // With no room, a step takes input until the buffer is full and stops
  // with a block's output waiting; steps with room and no input then hand
  // it out. Random bytes make stored blocks, whose output is the largest.
  let text = @fixtures.sample(12, 300000)
  let random = Bytes::makei(300000, i => ((i * 7919) >> 3).to_byte()) +
    @fixtures.sample(16, 1000)
  let rng = @fixtures.Rng::new(16)
  let noise = Bytes::makei(200000, _ => (rng.below(1 << 16) >> 8).to_byte())
  let dictionary = @fixtures.sample(17, 40000)
  for level in 0..<=9 {
    let (in_size, out_size) = encoder_buffers(level)
    for data in [text, random, noise, Bytes::make(150000, b'\x00')] {
      for with_dictionary in [false, true] {
        let encoder = if with_dictionary {
          Encoder(level~, dictionary~)
        } else {
          Encoder(level~)
        }
        // The dictionary's last 32 KiB start the window (not at level 0).
        let preset = if with_dictionary && level > 0 { 32768 } else { 0 }
        let none = FixedArray::make(0, b'\x00')
        let room = FixedArray::make(1 << 16, b'\x00')
        let mut pos = 0
        let mut most_out = 0
        let mut steps = 0
        for ;; {
          steps += 1
          let action : EncodeAction = if steps % 5 == 0 {
            Flush
          } else if pos + 120000 >= data.length() {
            Finish
          } else {
            Continue
          }
          let end = (pos + 120000).min(data.length())
          let status = encoder.step_into(data[pos:end], none, action~)
          assert_eq(encoder.last_produced(), 0)
          if steps == 1 {
            // The buffer fills up before the first block is written.
            assert_eq(encoder.last_consumed(), in_size - preset)
          }
          pos += encoder.last_consumed()
          let (held, waiting) = encoder.deflater.waiting()
          most_out = most_out.max(waiting)
          assert_true(held <= in_size && waiting <= out_size)
          // Input not taken waits for the next round, so the steps that
          // hand out the output take none and say Continue.
          let mut drained = status
          while drained is NeedMoreOutput {
            drained = encoder.step_into(b"", room, action=Continue)
            let (held, waiting) = encoder.deflater.waiting()
            assert_true(held <= in_size && waiting <= out_size)
          }
          if drained is Done {
            break
          }
        }
        assert_eq(pos, data.length())
        // Noise fills a stored block.
        if physical_equal(data, noise) {
          assert_true(most_out >= 65535 + 5, msg="level \{level}: \{most_out}")
        }
      }
    }
  }
}

///|
test "the encoder keeps the last 32 KiB of a dictionary, by reference" {
  for size in [0, 100, 32768, 40000] {
    let dictionary = @fixtures.sample(13, size)
    let encoder = Encoder(dictionary~)
    let kept = encoder.deflater.dictionary()
    if size > 0 {
      assert_true(physical_equal(kept.data(), dictionary))
    }
    assert_eq(kept.start_offset() + kept.length(), dictionary.length())
    assert_eq(kept.length(), size.min(32768))
    assert_eq(encoder.memory_usage(), encoder_bound(6))
  }
}
