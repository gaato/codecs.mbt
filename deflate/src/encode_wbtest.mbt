///|
/// The encoders' inputs: empty, one byte, a short repeat, a mix of words,
/// random bytes and repeats, past several 16 KiB blocks and the 64 KiB input
/// ring, and zeros.
fn encoder_inputs() -> Array[Bytes] {
  [
    b"",
    b"x",
    b"hello, hello, hello",
    @fixtures.sample(1, 5000),
    @fixtures.sample(2, 200000),
    Bytes::make(100000, b'\x00'),
  ]
}

///|
test "compress round-trips through the decoder at every level" {
  let dictionary = @fixtures.sample(3, 40000)
  for level in -1..<=10 {
    for input in encoder_inputs() {
      let stream = compress(input, level~)
      assert_eq(decompress(stream), input, msg="level \{level}")
      let with_dictionary = compress(input, level~, dictionary~)
      let decoder = Decoder(dictionary~)
      let (got, _) = @fixtures.drive(
        decoder,
        with_dictionary,
        next_in=() => 1 << 20,
        next_out=() => 1 << 16,
      )
      assert_eq(got, input, msg="level \{level} with a dictionary")
    }
  }
}

///|
test "levels outside 0 to 9 are clamped" {
  let input = @fixtures.sample(4, 30000)
  assert_eq(compress(input, level=-5), compress(input, level=0))
  assert_eq(compress(input, level=42), compress(input, level=9))
  assert_eq(compress(input), compress(input, level=6))
  // Level 0 stores; higher levels compress.
  assert_true(compress(input, level=0).length() > input.length())
  assert_true(compress(input, level=1).length() < input.length())
  assert_true(
    compress(input, level=9).length() <= compress(input, level=1).length(),
  )
}

///|
test "any input split and output size give the same stream" {
  let input = @fixtures.sample(5, 120000)
  for level in [0, 1, 6, 9] {
    let whole = compress(input, level~)
    for shape in [(1, 1), (7, 3), (16642, 1), (999, 65536), (65536, 5)] {
      let (chunk, room) = shape
      let rng = @fixtures.Rng::new(chunk.reinterpret_as_uint())
      let got = @fixtures.encode(
        Encoder(level~),
        input,
        next_in=() => 1 + rng.below(chunk),
        next_out=() => room,
      )
      assert_eq(
        got,
        whole,
        msg="level \{level}, chunks of \{chunk}, room \{room}",
      )
    }
  }
}

///|
/// What a fresh decoder gives out for `stream` without `end`: it must take
/// all of it and ask for more.
fn decode_available(stream : BytesView, dictionary? : BytesView) -> Bytes raise {
  let decoder = Decoder(dictionary?)
  let out = FixedArray::make(1 << 16, b'\x00')
  let got = Buffer()
  let mut rest = stream
  for ;; {
    let status = decoder.step_into(rest, out, end=false)
    rest = rest[decoder.last_consumed():]
    got.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
    match status {
      NeedMoreOutput => continue
      NeedMoreInput if rest.length() == 0 => return got.to_bytes()
      _ => fail("the flushed stream answered \{Repr(status)}")
    }
  }
}

///|
test "a flush is a sync flush: the stream so far decodes to the input so far" {
  let input = @fixtures.sample(6, 50000)
  let dictionary = @fixtures.sample(7, 10000)
  for level in [0, 1, 6, 9] {
    for with_dictionary in [false, true] {
      let encoder = if with_dictionary {
        Encoder(level~, dictionary~)
      } else {
        Encoder(level~)
      }
      let stream = Buffer()
      let out = FixedArray::make(1 << 17, b'\x00')
      let mut pos = 0
      for cut in [0, 1, 1, 9000, 30000, 50000] {
        let before = stream.length()
        let status = encoder.step_into(input[pos:cut], out, action=Flush)
        assert_eq(status, NeedMoreInput)
        assert_eq(encoder.last_consumed(), cut - pos)
        stream.write_bytes(Bytes::from_array(out[:encoder.last_produced()]))
        let so_far = stream.to_bytes()
        if cut > pos || cut == 0 {
          // A new flush ends with an empty stored block.
          assert_eq(so_far[so_far.length() - 4:], b"\x00\x00\xff\xff")
        } else {
          // Nothing new since the last flush: nothing added.
          assert_eq(so_far.length(), before)
        }
        let got = if with_dictionary {
          decode_available(so_far, dictionary~)
        } else {
          decode_available(so_far)
        }
        assert_eq(
          got,
          input[:cut].to_owned(),
          msg="level \{level}, flush at \{cut}",
        )
        pos = cut
      }
      assert_false(encoder.is_finished())
      assert_eq(encoder.step_into(b"", out, action=Finish), Done)
      assert_true(encoder.is_finished())
      stream.write_bytes(Bytes::from_array(out[:encoder.last_produced()]))
      let got = if with_dictionary {
        let (got, _) = @fixtures.drive(
          Decoder(dictionary~),
          stream.to_bytes(),
          next_in=() => 1 << 20,
          next_out=() => 1 << 16,
        )
        got
      } else {
        decompress(stream.to_bytes())
      }
      assert_eq(got, input)
    }
  }
}

///|
test "steps after the end take no input and answer Done" {
  let encoder = Encoder()
  let out = FixedArray::make(64, b'\x00')
  assert_eq(encoder.step_into(b"abc", out, action=Finish), Done)
  assert_eq(
    decompress(Bytes::from_array(out[:encoder.last_produced()])),
    b"abc",
  )
  let actions : Array[EncodeAction] = [Continue, Flush, Finish]
  for action in actions {
    assert_eq(encoder.step(b"more", out.mut_view(), action~), Done)
    assert_eq(encoder.last_consumed(), 0)
    assert_eq(encoder.last_produced(), 0)
  }
  // `reset` starts again, the same as a new encoder.
  encoder.reset()
  assert_false(encoder.is_finished())
  let again = @fixtures.encode(encoder, b"abc", next_in=() => 1, next_out=() => {
    1
  })
  assert_eq(again, compress(b"abc"))
}

///|
test "reset keeps the level and the dictionary" {
  let input = @fixtures.sample(8, 70000)
  let dictionary = @fixtures.sample(9, 50000)
  for level in [0, 3, 9] {
    let encoder = Encoder(level~, dictionary~)
    let first = @fixtures.encode(encoder, input, next_in=() => 5000, next_out=() => {
      777
    })
    assert_eq(first, compress(input, level~, dictionary~))
    // Reset halfway through a stream, then again at the end.
    let half = FixedArray::make(100, b'\x00')
    ignore(encoder.step_into(input[:30000], half, action=Continue))
    encoder.reset()
    let second = @fixtures.encode(encoder, input, next_in=() => 1 << 20, next_out=() => {
      1 << 16
    })
    assert_eq(second, first)
  }
}

///|
/// The SHA-256 of `compress(input, level=n)` for n from 0 to 9, for a fixed
/// input: the same on every target (the gates run the tests on all four).
test "every target writes the same bytes" {
  let input = @fixtures.sample(1951, 100000)
  let digests = [
    for level in 0..<=9 => @fixtures.sha256(compress(input, level~))
  ]
  let dictionary = @fixtures.sample(1950, 40000)
  digests.push(@fixtures.sha256(compress(input, dictionary~)))
  inspect(
    digests.join("\n"),
    content=(
      #|bc0d0f696fdd12eddbd096a4dfd932847a9039faaffec3cc545a04ac8eeeaee9
      #|320043db04928a0682a06f8023b08d79db8aff9e0bafd82b8b5c5d67d048cb80
      #|d5399ac18c542d9fd270ce78c30b0f361c5a8ebf58aaebb386ef5649885ea007
      #|83377f4752fe3cca6b1fac6914748188dafcfdbc868362fd383e6589aeff8209
      #|35700490804022cc3d75c10d545dce8e5245b6ae7b7af5810ff5b5d52a7b03d8
      #|cdee654f6131016c1e7190cb7263c1db0c7d3707a70a88ca075d3fe652286978
      #|61677f9d23effde25fff6343197aa9e6028bc33fc444016c39eff6e897aa4285
      #|ef842b5bdc6c5fcd16ea913ed659d5a485589041e3c8989a14e86c047f37a81a
      #|d484d8076176b6e91370adad6e02d78dbc8881ef93538af0dd4fb6d236d52ddc
      #|d484d8076176b6e91370adad6e02d78dbc8881ef93538af0dd4fb6d236d52ddc
      #|b86beb2d5fa3e435505b688e2b43e90cf94671b98e00fb98f5c7fc0f992334ad
    ),
  )
}

///|
/// What a codec reports through `gaato/codec_bytes`'s `Encode`.
fn[E : @codec_bytes.Encode] through_trait(encoder : E) -> (Int32, Int32) {
  let before = encoder.memory_usage()
  encoder.reset()
  (before, encoder.memory_usage())
}

///|
test "the Encode trait reaches the encoder's own methods" {
  let encoder = Encoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  ignore(encoder.step_into(b"abc", out, action=Finish))
  let (before, after) = through_trait(encoder)
  assert_eq(before, encoder.memory_usage())
  assert_eq(after, encoder.memory_usage())
  assert_false(encoder.is_finished())
}
