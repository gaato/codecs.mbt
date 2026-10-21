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
  let header = headers()[headers().length() - 1]
  let flush_at = [0, 1, 1, 30000, 65537, 120000]
  for level in 0..<=9 {
    let whole = compress(input, level~)
    let named = compress(input, level~, header~)
    let plain = Encoder(level~)
    let with_header = Encoder(level~, header~)
    let flushed = encode_split(
      plain,
      input,
      (1 << 20, 1 << 16, false),
      flush_at~,
    )
    for shape in split_shapes {
      let msg = "level \{level}, \{shape.0}, \{shape.1}, \{shape.2}"
      assert_eq(encode_split(plain, input, shape), whole, msg~)
      assert_eq(encode_split(with_header, input, shape), named, msg~)
      assert_eq(encode_split(plain, input, shape, flush_at~), flushed, msg~)
    }
    assert_eq(decompress(flushed), input)
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
      #|e0254d6b56d84e23399d1788869b6edf9a591d869faafacc8c5af4ecadb99736
      #|cf012af05302717959464ad5671fdc15e6ccde24aa4fb46697a5c4b3180cadde
      #|5994a81dad5d481ba9ff102bdc80ce500a67874432af2539067e5b674babf31c
      #|d5b29d82c3bba43facf61198190ea5f33e7ded8a0c87966991db0c1e3d917d7a
      #|786ee9c9453462eb49252d960045ce661ba29871acba10bbf46ceae085382643
      #|5f5c0201a7558954bd020546632237ca7fd55a22ed9012b9bb4a8d586a0375cd
      #|362632e09527fcc2bdcfb134b9755de2fc27b26b2cfa26a0252f6a8ef8182a09
      #|96af12f9ae956f94030fe7f609ab0ac6641b357cfdb9e4d733dc4bf074331c6b
      #|8ec6aaea44695cb726021ca965222c0bb203de224863e8bc3a52dbd4214f8d62
      #|ab4a14df4a863cd7910a884918e53c60bf004f45312f2fb25c0ab55013d2bac9
      #|c895599e92238265e67cbb2db46b4e7599b34fc2ff12b1c591467898f2868a8c
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
