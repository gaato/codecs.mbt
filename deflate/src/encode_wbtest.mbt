///|
/// The encoders' inputs: empty, one byte, a short repeat, a mix of words,
/// random bytes and repeats, past several 64 KiB blocks and the input
/// buffer, and zeros.
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
test "the shortest streams: empty, short and after a flush" {
  // An empty stream is a fixed block with only its end, as zlib writes it,
  // and stored at level 0.
  assert_eq(compress(b""), b"\x03\x00")
  assert_eq(compress(b"", level=1), b"\x03\x00")
  assert_eq(compress(b"", level=0), b"\x01\x00\x00\xff\xff")
  // At most 55 - 4 × level bytes with no dictionary are stored as they
  // are, as libdeflate stores them; one more is compressed.
  let short = b"hello, hello, hello, hello!!!!!"
  assert_eq(short.length(), 31)
  assert_eq(compress(short), b"\x01\x1f\x00\xe0\xff" + short)
  let longer = short + b"!"
  assert_true(compress(longer).length() < longer.length())
  assert_true(compress(short, dictionary=b"hello, ").length() < short.length())
  // A stream that ends right after a flush ends with an empty fixed block.
  let encoder = Encoder()
  let out = FixedArray::make(64, b'\x00')
  assert_eq(encoder.step_into(short, out, action=Flush), NeedMoreInput)
  let flushed = Bytes::from_array(out[:encoder.last_produced()])
  assert_eq(flushed[flushed.length() - 4:], b"\x00\x00\xff\xff")
  assert_eq(encoder.step_into(b"", out, action=Finish), Done)
  assert_eq(Bytes::from_array(out[:encoder.last_produced()]), b"\x03\x00")
  assert_eq(decompress(flushed + b"\x03\x00"), short)
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
/// How the split tests cut the input and the output: chunks of `chunk`
/// bytes (or of 1 to `chunk` bytes, drawn, with `random`), into slices of
/// `room` bytes. Chunks of a byte, of 7, of a few thousand, and of 64 KiB and
/// a little more, around the encoder's 65,535-byte blocks; slices of a byte,
/// of 977 and of 64 KiB.
let split_shapes : Array[(Int32, Int32, Bool)] = [
  (1, 977, false),
  (7, 1, false),
  (1000, 65536, false),
  (4097, 977, false),
  (65536, 1, false),
  (65539, 65536, false),
  (5000, 977, true),
  (70000, 3, true),
]

///|
/// `input` through `encoder` cut as `shape` says, with flushes at `flush_at`.
fn encode_split(
  encoder : Encoder,
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
    next_out=() => room,
    flush_at~,
  )
}

///|
test "any input split and output size give the same stream, at every level" {
  // Words, random bytes and repeats over two blocks, and a run of zeros,
  // where matches run up to the end of a block and over it.
  let input = @fixtures.sample(5, 110000) + Bytes::make(10000, b'\x00')
  for level in 0..<=9 {
    let whole = compress(input, level~)
    let encoder = Encoder(level~)
    for shape in split_shapes {
      assert_eq(
        encode_split(encoder, input, shape),
        whole,
        msg="level \{level}, \{shape.0}, \{shape.1}, \{shape.2}",
      )
    }
  }
}

///|
test "any split gives the same stream with a dictionary and with flushes" {
  let input = @fixtures.sample(14, 100000)
  let dictionary = @fixtures.sample(15, 40000)
  // Flushes at the start, twice in a row, a byte apart, and within a match's
  // reach of a block's end; the last at the end of the input.
  let flush_at = [0, 1, 1, 2, 9000, 65534, 65540, 100000]
  for level in 0..<=9 {
    let named = Encoder(level~, dictionary~)
    let with_dictionary = compress(input, level~, dictionary~)
    let flushed = encode_split(
      named,
      input,
      (1 << 20, 1 << 16, false),
      flush_at~,
    )
    let plain = Encoder(level~)
    let flushed_plain = encode_split(
      plain,
      input,
      (1 << 20, 1 << 16, false),
      flush_at~,
    )
    for shape in split_shapes {
      let msg = "level \{level}, \{shape.0}, \{shape.1}, \{shape.2}"
      assert_eq(encode_split(named, input, shape), with_dictionary, msg~)
      assert_eq(encode_split(named, input, shape, flush_at~), flushed, msg~)
      assert_eq(
        encode_split(plain, input, shape, flush_at~),
        flushed_plain,
        msg~,
      )
    }
    // Each stream decodes to the input, through this module's decoder.
    let (got, _) = @fixtures.drive(
      Decoder(dictionary~),
      flushed,
      next_in=() => 1 << 20,
      next_out=() => 1 << 16,
    )
    assert_eq(got, input, msg="level \{level}")
    assert_eq(decompress(flushed_plain), input, msg="level \{level}")
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
  for level in 0..<=9 {
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
/// The ten are also the bytes that libdeflate 1.24 writes for this input at
/// each level when built with the encoder's block limits
/// (SOFT_MAX_BLOCK_LENGTH 65,535, SEQ_STORE_LENGTH 16,384, and
/// choose_max_block_end without MIN_BLOCK_LENGTH), checked when they were
/// made.
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
      #|90a1187ac89e94ee2715b7c10e796f376c69130a60517ec727fe333cd5abdfdc
      #|3409032bcd13ffbd3b47c71178e7c886d39b27fd10d6c7255f59b605515719c5
      #|0ac431cf14dcfa4618e06e34110f9536382311955f6726cd5cb692f3b4cb44ca
      #|b760c0ddb03b13e248ecefd836d3be5b4e402e3fcf156921a29b3d06a796d3ff
      #|b7c8e2c1b8da454deaef94ee5b0fa988ae622606b5599e42a849b08f5192630f
      #|8803d99bbb96acf1c1d583029a2b2aeec6fee597132f9aaa6a665940cd3212ea
      #|3dc1798beba670d683faaac672dc6e88bb119badd2c6a03998cd86eda411fa6f
      #|897bff0b48bc03994466aa69b02d7b9464f05816d958f2a4c776b4d745ad12ad
      #|1ce25ac7cedf61bebfae8ac9956fd5051f45741d71f00983e04986a78ab66bcb
      #|6a6285da9b35d69fde0c475e870dafccfb2add069d277ac7da76014b855843ac
      #|a55acfb4da054e39fda2aac3fa6106a159a9e161274faf378d6018262056ad86
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
