///|
/// What `memory_usage` reports, with a dictionary or without.
const BOUND : Int32 = WINDOW_SIZE + LINK_TABLE_BYTES + STAGED_BYTES

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
  assert_eq(d.memory_usage(), BOUND)
}

///|
test "output slices and reported memory stay within their bounds" {
  inspect(BOUND, content="74240")
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
    content="74240",
  )
}

///|
test "the encoder reports its bound after every step" {
  inspect(ENCODER_BYTES, content="689394")
  let input = @fixtures.sample(10, 150000)
  let dictionary = @fixtures.sample(11, 40000)
  for level in 0..<=9 {
    for encoder in [Encoder(level~), Encoder(level~, dictionary~)] {
      assert_eq(encoder.memory_usage(), ENCODER_BYTES)
      let rng = @fixtures.Rng::new(level.reinterpret_as_uint())
      let _ = @fixtures.encode(
        encoder,
        input,
        next_in=() => 1 + rng.below(40000),
        next_out=() => rng.below(3000),
        flush_every=50000,
        check=(e, _) => assert_eq(e.memory_usage(), ENCODER_BYTES),
      )
      encoder.reset()
      assert_eq(encoder.memory_usage(), ENCODER_BYTES)
    }
  }
}

///|
test "the encoder holds at most a block of input and its output" {
  // With no room, a step takes input until a block and its look-ahead wait,
  // 16,642 bytes, and stops with that block's output waiting; steps with
  // room, no input and `Continue` then hand out everything that waits.
  let input = @fixtures.sample(12, 300000)
  let random = Bytes::makei(100000, i => ((i * 7919) >> 3).to_byte())
  for level in 0..<=9 {
    for data in [input, random, Bytes::make(100000, b'\x00')] {
      let encoder = Encoder(level~)
      let none = FixedArray::make(0, b'\x00')
      let room = FixedArray::make(1 << 16, b'\x00')
      let mut pos = 0
      let mut most_in = 0
      let mut most_out = 0
      let mut steps = 0
      for ;; {
        steps += 1
        let action : EncodeAction = if steps % 5 == 0 {
          Flush
        } else if pos + 20000 >= data.length() {
          Finish
        } else {
          Continue
        }
        let end = (pos + 20000).min(data.length())
        let status = encoder.step_into(data[pos:end], none, action~)
        assert_eq(encoder.last_produced(), 0)
        most_in = most_in.max(encoder.last_consumed())
        pos += encoder.last_consumed()
        let mut waiting = 0
        let mut drained = status
        while !(drained is Done) {
          drained = encoder.step_into(b"", room, action=Continue)
          waiting += encoder.last_produced()
          if drained is NeedMoreInput {
            break
          }
        }
        most_out = most_out.max(waiting)
        if drained is Done {
          break
        }
      }
      assert_eq(pos, data.length())
      assert_true(most_in <= 16384 + 258, msg="level \{level}: \{most_in} in")
      // A block and a flush's empty stored block, each at most their stored
      // size: well within the 32 KiB the output's capacity is counted at.
      assert_true(
        most_out <= 16384 + 258 + 2 * 6 + 6,
        msg="level \{level}: \{most_out} out",
      )
    }
  }
}

///|
test "the encoder keeps the last 32 KiB of a dictionary, by reference" {
  for size in [0, 100, 32768, 40000] {
    let dictionary = @fixtures.sample(13, size)
    let encoder = Encoder(dictionary~)
    let kept = encoder.dictionary.unwrap()
    assert_true(physical_equal(kept.data(), dictionary))
    assert_eq(kept.start_offset() + kept.length(), dictionary.length())
    assert_eq(kept.length(), size.min(32768))
    assert_eq(encoder.memory_usage(), ENCODER_BYTES)
  }
}
