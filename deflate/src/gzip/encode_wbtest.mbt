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
/// Headers with every combination of the optional fields.
fn headers() -> Array[Header] {
  let fields : Array[Bytes?] = [None, Some(b""), Some(b"name.txt")]
  let extras : Array[Bytes?] = [
    None,
    Some(b""),
    Some(b"AB\x02\x00hi"),
    Some(Bytes::make(65535, b'e')),
  ]
  let out = []
  for text in [false, true] {
    for extra in extras {
      for name in fields {
        for comment in fields {
          out.push({
            text,
            mtime: 1700000000,
            xfl: b'\x02',
            os: b'\x03',
            extra,
            name,
            comment,
          })
        }
      }
    }
  }
  out
}

///|
/// Decodes one member, `stream`, and returns its data and its header.
fn decode(stream : Bytes) -> (Bytes, Header?) raise {
  let decoder = Decoder(max_header_bytes=1 << 20)
  let (got, consumed) = @fixtures.drive(
    decoder,
    stream,
    next_in=() => 1 << 20,
    next_out=() => 1 << 16,
  )
  assert_eq(consumed, stream.length())
  (got, decoder.header())
}

///|
test "compress round-trips through the decoder at every level" {
  for level in -1..<=10 {
    for input in encoder_inputs() {
      assert_eq(
        decompress(compress(input, level~)),
        input,
        msg="level \{level}",
      )
    }
  }
}

///|
test "the default header: no fields, MTIME 0, OS 255, XFL as zlib sets it" {
  for level in -1..<=10 {
    let stream = compress(b"", level~)
    let xfl = match level.clamp(min=0, max=9) {
      0 | 1 => b'\x04'
      9 => b'\x02'
      _ => b'\x00'
    }
    assert_eq(stream[:10], [0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, xfl, 0xff])
    let (_, header) = decode(stream)
    assert_eq(
      header,
      Some({
        text: false,
        mtime: 0,
        xfl,
        os: b'\xff',
        extra: None,
        name: None,
        comment: None,
      }),
    )
  }
  // The empty member, byte for byte.
  assert_eq(
    compress(b""),
    b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff\x03\x00\x00\x00\x00\x00\x00\x00\x00\x00",
  )
}

///|
test "a given header is written as it is, and reads back" {
  let input = @fixtures.sample(3, 20000)
  for header in headers() {
    assert_true(header.is_writable())
    let stream = compress(input, header~)
    let (got, read) = decode(stream)
    assert_eq(got, input)
    assert_eq(read, Some(header))
    // The header, raw DEFLATE, then the CRC-32 and the length.
    let raw = @deflate.compress(input)
    let built = @header.build(
      text=header.text,
      mtime=header.mtime,
      xfl=header.xfl,
      os=header.os,
      extra=header.extra,
      name=header.name,
      comment=header.comment,
    )
    let trailer = @header.trailer(
      @crc32.update_bytes(@crc32.INITIAL, input),
      input.length().reinterpret_as_uint(),
    )
    assert_eq(stream, built + raw + trailer)
  }
}

///|
test "is_writable: an extra field that fits, no zero in the name or the comment" {
  let header : Header = {
    text: false,
    mtime: 0,
    xfl: b'\x00',
    os: b'\xff',
    extra: None,
    name: None,
    comment: None,
  }
  assert_true(header.is_writable())
  assert_true(
    { ..header, extra: Some(Bytes::make(65535, b'\x00')), }.is_writable(),
  )
  assert_false(
    { ..header, extra: Some(Bytes::make(65536, b'e')), }.is_writable(),
  )
  assert_false({ ..header, name: Some(b"a\x00"), }.is_writable())
  assert_false({ ..header, comment: Some(b"\x00b"), }.is_writable())
  // The extra field is not checked for subfields.
  assert_true({ ..header, extra: Some(b"\x01"), }.is_writable())
}

///|
test "panic an encoder given a header it cannot write aborts" {
  let header : Header = {
    text: false,
    mtime: 0,
    xfl: b'\x00',
    os: b'\xff',
    extra: None,
    name: Some(b"a\x00b"),
    comment: None,
  }
  ignore(Encoder(header~))
}

///|
test "panic compress given a header it cannot write aborts" {
  let header : Header = {
    text: false,
    mtime: 0,
    xfl: b'\x00',
    os: b'\xff',
    extra: Some(Bytes::make(65536, b'e')),
    name: None,
    comment: None,
  }
  ignore(compress(b"x", header~))
}

///|
test "any input split and output size give the same stream" {
  let input = @fixtures.sample(5, 120000)
  let header = headers()[headers().length() - 1]
  for level in [0, 1, 6, 9] {
    let whole = compress(input, level~)
    let named = compress(input, level~, header~)
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
        Encoder(level~, header~),
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
  let input = @fixtures.sample(6, 50000)
  let encoder = Encoder()
  let out = FixedArray::make(1 << 17, b'\x00')
  let stream = Buffer()
  let mut pos = 0
  for cut in [0, 1, 20000, 50000] {
    assert_eq(
      encoder.step_into(input[pos:cut], out, action=Flush),
      NeedMoreInput,
    )
    stream.write_bytes(Bytes::from_array(out[:encoder.last_produced()]))
    let decoder = Decoder()
    let decoded = FixedArray::make(1 << 17, b'\x00')
    let so_far = stream.to_bytes()
    assert_eq(decoder.step_into(so_far, decoded, end=false), NeedMoreInput)
    assert_eq(decoder.last_consumed(), so_far.length())
    assert_eq(
      Bytes::from_array(decoded[:decoder.last_produced()]),
      input[:cut].to_owned(),
    )
    pos = cut
  }
  assert_eq(encoder.step_into(b"", out, action=Finish), Done)
  stream.write_bytes(Bytes::from_array(out[:encoder.last_produced()]))
  assert_eq(decompress(stream.to_bytes()), input)
}

///|
test "steps after the end take no input; reset starts again" {
  let header = headers()[5]
  let encoder = Encoder(level=1, header~)
  let out = FixedArray::make(1 << 17, b'\x00')
  assert_false(encoder.is_finished())
  assert_eq(encoder.step_into(b"abc", out, action=Finish), Done)
  assert_true(encoder.is_finished())
  let stream = Bytes::from_array(out[:encoder.last_produced()])
  assert_eq(stream, compress(b"abc", level=1, header~))
  let actions : Array[EncodeAction] = [Continue, Flush, Finish]
  for action in actions {
    assert_eq(encoder.step(b"more", out.mut_view(), action~), Done)
    assert_eq(encoder.last_consumed(), 0)
    assert_eq(encoder.last_produced(), 0)
  }
  encoder.reset()
  assert_false(encoder.is_finished())
  ignore(encoder.step_into(@fixtures.sample(8, 30000), out, action=Continue))
  encoder.reset()
  let again = @fixtures.encode(encoder, b"abc", next_in=() => 1, next_out=() => {
    1
  })
  assert_eq(again, stream)
}

///|
/// The SHA-256 of `compress(input, level=n)` for n from 0 to 9, and with a
/// header: the same on every target (the gates run the tests on all four).
test "every target writes the same bytes" {
  let input = @fixtures.sample(1952, 100000)
  let digests = [
    for level in 0..<=9 => @fixtures.sha256(compress(input, level~))
  ]
  digests.push(@fixtures.sha256(compress(input, header=headers()[20])))
  inspect(
    digests.join("\n"),
    content=(
      #|077bd8ebc99db3fe3d12f74e8bad4ce2c458924f821fa5389b51728d412f5e75
      #|b9f5dca0e5290c086b8e411805e8e07f0de8ac3f2e32cb48a7b2c858f0c66f53
      #|2e75f606a5be4a12a35c08332af634cc4d5b320d252ae1d6f884202a3362b12f
      #|00a84ae69d2758bf7c406f47dfb534357633512b6cdfe4512719d0664d3f4fc9
      #|cd5cef9e4166956aa33d0b934f95c50d91dd7498304e8f0c7fbdc08adf8871f5
      #|b6e632bdce53d70fcc63a65c3f095e4af93eca8f00ad1b3bdf90113a113e1d94
      #|4a32aba664b46285615a125e8d46b540d8394dc735a871e8d7bffc690e174073
      #|1608a58ef88283b608a1f18b86e52476bbf62b6438565c2a8c39a5ada3e61c0f
      #|31ac2e3fd11ecaca9495310548a3a223733e1e40ab099c6f7bb7c91e451544cc
      #|b0ea48fd307a6bf0eba883ae7f0a4eafddcea964993f0e76423149af735f9a2c
      #|90fa6e0cb28fe751245358d07a7a9b3f786cbe0d996d8e20902ea3b96791f507
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
