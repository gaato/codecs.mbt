///|
/// The encoders' inputs: empty, one byte, a short repeat, a mix of words,
/// random bytes and repeats past several blocks, and zeros.
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
      assert_eq(
        decompress(compress(input, level~)),
        input,
        msg="level \{level}",
      )
      let named = compress(input, level~, dictionary~)
      assert_eq(decompress(named, dictionary~), input, msg="level \{level}")
    }
  }
}

///|
test "a stream is the header, raw DEFLATE and the Adler-32" {
  let dictionary = @fixtures.sample(4, 1000)
  for level in -1..<=10 {
    for input in encoder_inputs() {
      let raw = @deflate.compress(input, level~)
      let expected = @header.build(level.clamp(min=0, max=9), None) +
        raw +
        @header.put_be32(@adler32.of_bytes(input))
      assert_eq(compress(input, level~), expected)
      let raw = @deflate.compress(input, level~, dictionary~)
      let expected = @header.build(level, Some(dictionary_id(dictionary))) +
        raw +
        @header.put_be32(@adler32.of_bytes(input))
      assert_eq(compress(input, level~, dictionary~), expected)
    }
  }
  // The empty stream, byte for byte as zlib writes it at its default level.
  assert_eq(compress(b""), b"\x78\x9c\x03\x00\x00\x00\x00\x01")
  assert_eq(compress(b"", level=1), b"\x78\x01\x03\x00\x00\x00\x00\x01")
}

///|
test "any input split and output size give the same stream" {
  let input = @fixtures.sample(5, 120000)
  let dictionary = @fixtures.sample(6, 5000)
  for level in [0, 1, 6, 9] {
    let whole = compress(input, level~)
    let named = compress(input, level~, dictionary~)
    for shape in [(1, 1), (7, 3), (16642, 1), (999, 65536), (65536, 5)] {
      let (chunk, room) = shape
      let rng = @fixtures.Rng::new(chunk.reinterpret_as_uint())
      let got = @fixtures.encode(
        Encoder(level~),
        input,
        next_in=() => 1 + rng.below(chunk),
        next_out=() => rng.below(room + 1),
      )
      assert_eq(
        got,
        whole,
        msg="level \{level}, chunks of \{chunk}, room \{room}",
      )
      let got = @fixtures.encode(
        Encoder(level~, dictionary~),
        input,
        next_in=() => 1 + rng.below(chunk),
        next_out=() => room,
      )
      assert_eq(
        got,
        named,
        msg="level \{level}, chunks of \{chunk}, room \{room}",
      )
    }
  }
}

///|
test "a flush makes the stream so far decode to the input so far" {
  // As Discord's zlib-stream does: each message ends in a sync flush, and a
  // decoder given the stream so far without `end` gives out every message.
  let messages = [
    b"{\"op\":10,\"d\":{\"heartbeat_interval\":41250}}",
    b"",
    @fixtures.sample(7, 40000),
    b"{\"op\":11}",
  ]
  let encoder = Encoder()
  let decoder = Decoder()
  let out = FixedArray::make(1 << 17, b'\x00')
  let decoded = FixedArray::make(1 << 17, b'\x00')
  for message in messages {
    assert_eq(encoder.step_into(message, out, action=Flush), NeedMoreInput)
    let part = Bytes::from_array(out[:encoder.last_produced()])
    if message.is_empty() {
      // Nothing new since the last flush: nothing to send.
      assert_eq(part, b"")
    } else {
      assert_eq(part[part.length() - 4:], b"\x00\x00\xff\xff")
    }
    assert_eq(decoder.step_into(part, decoded, end=false), NeedMoreInput)
    assert_eq(decoder.last_consumed(), part.length())
    assert_eq(Bytes::from_array(decoded[:decoder.last_produced()]), message)
  }
  assert_eq(encoder.step_into(b"", out, action=Finish), Done)
  let last = Bytes::from_array(out[:encoder.last_produced()])
  assert_eq(decoder.step_into(last, decoded, end=true), Done)
  assert_eq(decoder.last_produced(), 0)
}

///|
test "steps after the end take no input; reset starts again" {
  let encoder = Encoder(level=9)
  let out = FixedArray::make(64, b'\x00')
  assert_false(encoder.is_finished())
  assert_eq(encoder.step_into(b"abc", out, action=Finish), Done)
  assert_true(encoder.is_finished())
  let stream = Bytes::from_array(out[:encoder.last_produced()])
  assert_eq(stream, compress(b"abc", level=9))
  let actions : Array[EncodeAction] = [Continue, Flush, Finish]
  for action in actions {
    assert_eq(encoder.step(b"more", out.mut_view(), action~), Done)
    assert_eq(encoder.last_consumed(), 0)
    assert_eq(encoder.last_produced(), 0)
  }
  encoder.reset()
  assert_false(encoder.is_finished())
  // Halfway through a stream, then reset: the same as a new encoder.
  ignore(encoder.step_into(@fixtures.sample(8, 30000), out, action=Continue))
  encoder.reset()
  let again = @fixtures.encode(encoder, b"abc", next_in=() => 1, next_out=() => {
    1
  })
  assert_eq(again, stream)
}

///|
/// The SHA-256 of `compress(input, level=n)` for n from 0 to 9, and with a
/// dictionary: the same on every target (the gates run the tests on all
/// four).
test "every target writes the same bytes" {
  let input = @fixtures.sample(1950, 100000)
  let digests = [
    for level in 0..<=9 => @fixtures.sha256(compress(input, level~))
  ]
  let dictionary = @fixtures.sample(1951, 40000)
  digests.push(@fixtures.sha256(compress(input, dictionary~)))
  inspect(
    digests.join("\n"),
    content=(
      #|c6b5caff69a94cb0daf382851b9e082339bd202b562bf13856cc666f6bfb5f73
      #|1706f902598fec4510195fd5b10b3ba598a29fcb20ed4c17d42f067a44afa8d4
      #|28c6e611b8219c525485995c6e72972d205c4a4e16ffc4f047f10bcc3122358f
      #|bf2fe43f9d4b816e08654c289960470dadf40f82f1b65bee4da982f10c4d3910
      #|042cc7f16496961e34b569b5d11efb34b91ddd203143f8e61a4fa03d122de061
      #|a1d5e7f9f266d0b9988a0a3427742ce2eedda50e55a4ee10165b02d821644516
      #|c450b1da70eea26b21ce19af78ac343a67bc4cf553e54db6d035719c16b70df6
      #|cddc7d4c46758e2609bc335780651fe2d9740cfc94befcde4b0cda866c4eee8d
      #|cd374080a79deb74fc52a89b2c4718ba44cfa96ef17635a75142c188a4c4c553
      #|42cb4f23f97076c62aa189417862a3c0951f3e3892582dd6d3f7334fb5193304
      #|81aecec1230651ba707fa1c1b8f46479d772910430eb62c7b65a82c8f194a3f6
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
