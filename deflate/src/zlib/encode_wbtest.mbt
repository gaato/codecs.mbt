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
/// How the split tests cut the input and the output: chunks of `chunk`
/// bytes (or of 1 to `chunk`, drawn, with `random`), into slices of `room`
/// bytes (or of 0 to `room`).
let split_shapes : Array[(Int32, Int32, Bool)] = [
  (1, 977, false),
  (7, 1, false),
  (1000, 65536, false),
  (4097, 977, true),
  (65536, 1, false),
  (65539, 65536, true),
]

///|
fn[E : @codec_bytes.Encode] encode_split(
  encoder : E,
  input : Bytes,
  shape : (Int32, Int32, Bool),
  flush_at~ : Array[Int32] = [],
) -> Bytes raise {
  let (chunk, room, random) = shape
  let rng = @fixtures.Rng::new(chunk.reinterpret_as_uint())
  encoder.reset()
  @fixtures.encode(
    encoder,
    input,
    next_in=() => if random { 1 + rng.below(chunk) } else { chunk },
    next_out=() => if random { rng.below(room + 1) } else { room },
    flush_at~,
  )
}

///|
test "any input split and output size give the same stream" {
  let input = @fixtures.sample(5, 120000)
  let dictionary = @fixtures.sample(6, 5000)
  let flush_at = [0, 1, 1, 30000, 65537, 120000]
  for level in 0..<=9 {
    let whole = compress(input, level~)
    let named = compress(input, level~, dictionary~)
    let plain = Encoder(level~)
    let with_dictionary = Encoder(level~, dictionary~)
    let flushed = encode_split(
      plain,
      input,
      (1 << 20, 1 << 16, false),
      flush_at~,
    )
    for shape in split_shapes {
      let msg = "level \{level}, \{shape.0}, \{shape.1}, \{shape.2}"
      assert_eq(encode_split(plain, input, shape), whole, msg~)
      assert_eq(encode_split(with_dictionary, input, shape), named, msg~)
      assert_eq(encode_split(plain, input, shape, flush_at~), flushed, msg~)
    }
    assert_eq(decompress(flushed), input)
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
      #|542df6f215dae39c4495f06039e266309962c18eeea4c93b36db7c4b62bc4476
      #|6384e8f0cf94cdcb43a10df51832ddf6248a1bf0d1994df659f9b10b0f6a95b9
      #|a7512010eba9d969a046d16e56857c34bf766021ccfc5b78e42f122c31f673dd
      #|81cbf2e570690d40f9cfdb42bf4da3831e94454af44e132f34567c90e74c9b60
      #|005709cfb8f8a7ce5e45d788063192a1da8c966b20ce7eebce2e4a5cbb4991d5
      #|947dad438e18877907f24927cce7bcd8739946006e44ca0d4a4d114c8c6a47c5
      #|79f2994b2b78ad52318d0e9c47d87ef7329cd107f828e302d5f570bb8b99b235
      #|ffcf59cc211b947fbd3c04117f61c211354530442389f486cebe9f0a8164a094
      #|858e32d70f0170a96905e36b42f9ea0e52d882b377396bdb98cd49a3f776587d
      #|afc3e55938eab20c775075be96cf2d796a08372a1399ab66b611cb17f7fcaf23
      #|78fba0ea070f1a1c451ca0c4a925bf319960965c4893ab3d9ab35aae54dbb8b4
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
