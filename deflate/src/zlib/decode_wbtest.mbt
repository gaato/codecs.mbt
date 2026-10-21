///|
test "every vector decodes to its original" {
  for v in vectors {
    let got = decompress(v.input())
    assert_eq(got.length(), v.size, msg=v.name)
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
  }
}

///|
/// The kind of error `decompress` raises on `input` with `dictionary`.
fn dictionary_refusal(
  input : BytesView,
  dictionary? : BytesView,
) -> @codec.ErrorKind raise {
  try decompress(input, dictionary?) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
}

///|
test "preset dictionaries: required, matched by their Adler-32, and kept by reset" {
  for entry in dictionary_vectors {
    let (v, dictionary) = entry
    let dictionary = @fixtures.decode64(dictionary)
    let input = v.input()
    let got = decompress(input, dictionary~)
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
    // DICTID, big-endian after CMF and FLG, is the dictionary's Adler-32.
    let id = @header.be32(input[2:6])
    assert_eq(id, @adler32.of_bytes(dictionary))
    assert_eq(dictionary_refusal(input), DictionaryRequired(Some(id)))
    assert_eq(
      dictionary_refusal(input, dictionary=dictionary[1:]),
      DictionaryMismatch,
    )
    let decoder = Decoder(dictionary~)
    for _ in 0..<2 {
      let (again, _) = @fixtures.drive(
        decoder,
        input,
        next_in=() => 999,
        next_out=() => 1 << 16,
        step_into=into,
      )
      assert_eq(again, got, msg=v.name)
      decoder.reset()
    }
    // A stream that names no dictionary ignores the one given.
    let plain = vector("small_level6")
    let (ignored, _) = @fixtures.drive(
      decoder,
      plain.input(),
      next_in=() => 5,
      next_out=() => 77,
    )
    assert_eq(@fixtures.sha256(ignored), plain.sha256)
  }
}

///|
test "any fixed input split and output size give the same output" {
  let splits : Array[(Int32, Int32)] = [
    (1, 1 << 16),
    (1 << 20, 1),
    (1, 1),
    (3, 7),
    (7, 3),
    (64, 4096),
  ]
  for v in vectors {
    let input = v.input()
    for split in splits {
      let (in_chunk, out_chunk) = split
      if in_chunk * out_chunk < 64 && v.size > 20000 {
        continue
      }
      for fixed in [false, true] {
        let (got, consumed) = @fixtures.drive(
          Decoder(),
          input,
          next_in=() => in_chunk,
          next_out=() => out_chunk,
          step_into?=if fixed { Some(into) } else { None },
        )
        let label = "\{v.name} in \{in_chunk} out \{out_chunk}"
        assert_eq(@fixtures.sha256(got), v.sha256, msg=label)
        assert_eq(consumed, input.length(), msg=label)
      }
    }
  }
}

///|
test "every proper prefix is truncated" {
  for v in vectors {
    let input = v.input()
    guard input.length() <= 3000 else { continue }
    for cut in 0..<input.length() {
      assert_eq(refusal(input[:cut]), Truncated, msg="\{v.name} cut at \{cut}")
    }
  }
}

///|
test "until=EndOfMember leaves what follows the trailer, under every split" {
  let rest = b"what follows"
  for name in ["small_level6", "empty", "small_level0"] {
    let v = vector(name)
    let input = Bytes::from_array([..v.input(), ..rest])
    for split in [(1, 1), (3, 7), (1 << 20, 1 << 16)] {
      let (in_chunk, out_chunk) = split
      let decoder = Decoder(until=EndOfMember)
      let (got, consumed) = @fixtures.drive(
        decoder,
        input,
        next_in=() => in_chunk,
        next_out=() => out_chunk,
      )
      assert_eq(@fixtures.sha256(got), v.sha256, msg=name)
      assert_eq(input[consumed:], rest, msg=name)
      assert_true(decoder.is_finished())
      let out = FixedArray::make(8, b'\x00')
      assert_true(decoder.step_into(rest, out, end=true) is Done)
      assert_eq(decoder.last_consumed(), 0)
    }
  }
}

///|
test "until=EndOfInput: Done waits for end, and bytes after the stream are trailing" {
  let stream = vector("small_level9").input()
  let out = FixedArray::make(1 << 16, b'\x00')
  let decoder = Decoder()
  assert_true(decoder.step_into(stream, out, end=false) is NeedMoreInput)
  assert_true(decoder.is_finished())
  assert_true(decoder.step_into(b"", out, end=true) is Done)
  let after = try decoder.step_into(b"x", out, end=true) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(after, TrailingData)
  let later = Decoder()
  let _ = later.step_into(stream, out, end=false)
  let kind = try later.step_into(b"\x78", out, end=false) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(kind, TrailingData)
}

///|
test "a stream of sync-flushed messages, as Discord sends it" {
  let stream = @fixtures.decode64(flushed_vector.compressed)
  for split in [1, 7, 1 << 20] {
    let decoder = Decoder()
    let out = FixedArray::make(256, b'\x00')
    let mut from = 0
    for message in flushed_vector.messages {
      let (end, size, sha256) = message
      // Each message arrives in pieces; after its last byte the decoder has
      // given out all of it and asks for more.
      let text = Buffer()
      let mut pos = from
      while pos < end {
        let next = (pos + split).min(end)
        let mut chunk = stream[pos:next]
        for ;; {
          let status = decoder.step_into(chunk, out, end=false)
          chunk = chunk[decoder.last_consumed():]
          text.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
          if status is NeedMoreInput {
            break
          }
          assert_true(status is NeedMoreOutput)
        }
        pos = next
      }
      assert_eq(text.length(), size)
      assert_eq(@fixtures.sha256(text.to_bytes()), sha256)
      from = end
    }
    assert_false(decoder.is_finished())
  }
}

///|
test "errors stick until reset, with a kind and a message" {
  let message = (input : Bytes) => {
    try decompress(input) catch {
      CodecError(kind, message) => "\{Repr(kind)}: \{message}"
    } noraise {
      _ => "decoded"
    }
  }
  inspect(message(b""), content="Truncated: the input holds no stream")
  inspect(
    message(b"\x78"),
    content="Truncated: the stream ends inside its header or trailer",
  )
  inspect(
    message(b"\x78\x9d"),
    content="Corrupt: the header check (FCHECK) fails",
  )
  inspect(message(b"\x78\x9c\x07"), content="Corrupt: reserved block type")
  inspect(
    message(b"\x78\x9c\x03\x00\x00\x00\x00\x02"),
    content="ChecksumMismatch: the Adler-32 of the data does not match the stream's",
  )
  let decoder = Decoder()
  let out = FixedArray::make(8, b'\x00')
  for _ in 0..<2 {
    let kind = try decoder.step_into(b"\x78\x9d", out, end=false) catch {
      CodecError(kind, _) => kind
    } noraise {
      _ => fail("decoded")
    }
    assert_eq(kind, Corrupt)
    assert_eq(decoder.last_consumed(), 0)
  }
  decoder.reset()
  assert_true(
    decoder.step_into(b"\x78\x9c\x03\x00\x00\x00\x00\x01", out, end=true)
    is Done,
  )
}

///|
test "decompress honours max_output" {
  let v = vector("text_level6")
  assert_eq(decompress(v.input(), max_output=v.size).length(), v.size)
  let over = try decompress(v.input(), max_output=v.size - 1) catch {
    CodecError(LimitExceeded(limit), _) => Some(limit)
    _ => None
  } noraise {
    _ => None
  }
  assert_eq(over, Some({ resource: Output, needed: None, limit: 19999, }))
}

///|
test "is_header accepts exactly the headers the decoder reads" {
  inspect(is_header(b'\x78', b'\x9c'), content="true")
  inspect(is_header(b'\x78', b'\xda'), content="true")
  inspect(is_header(b'\x08', b'\x1d'), content="true")
  inspect(is_header(b'\x78', b'\x9d'), content="false")
  // Every vector's first two bytes pass.
  for v in vectors {
    let input = v.input()
    assert_true(is_header(input[0], input[1]), msg=v.name)
  }
  // 66 pairs of 65,536 pass, and each begins, read as raw DEFLATE, with a
  // non-final stored block with a padding bit set (the low four bits are
  // 1000), which encoders do not write.
  let mut passed = 0
  for cmf in 0..<256 {
    for flg in 0..<256 {
      if is_header(cmf.to_byte(), flg.to_byte()) {
        passed += 1
        assert_eq(cmf & 15, 8)
      }
    }
  }
  inspect(passed, content="66")
}

///|
test "the decoder is a gaato/codec_bytes Decode" {
  let v = vector("small_level6")
  let decoder = Decoder()
  for _ in 0..<2 {
    let (got, _) = @fixtures.drive(decoder, v.input(), next_in=() => 7, next_out=() => {
      10
    })
    assert_eq(@fixtures.sha256(got), v.sha256)
    assert_eq(
      @codec_bytes.Decode::memory_usage(decoder),
      decoder.memory_usage(),
    )
    @codec_bytes.Decode::reset(decoder)
  }
}
