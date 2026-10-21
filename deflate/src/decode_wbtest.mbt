///|
test "every vector decodes to its original" {
  for v in vectors {
    let got = decompress(v.input())
    assert_eq(got.length(), v.size, msg=v.name)
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "streams with a preset dictionary decode with it, and only with it" {
  for entry in dictionary_vectors {
    let (v, dictionary) = entry
    let dictionary = @fixtures.decode64(dictionary)
    let decoder = Decoder(dictionary~)
    let (got, _) = @fixtures.drive(decoder, v.input(), next_in=() => 1000, next_out=() => {
      4096
    })
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
    // `reset` keeps the dictionary.
    decoder.reset()
    let (again, _) = @fixtures.drive(
      decoder,
      v.input(),
      next_in=() => 1 << 20,
      next_out=() => 1 << 16,
      step_into=into,
    )
    assert_eq(again, got, msg=v.name)
    assert_eq(refusal(v.input()), Corrupt, msg=v.name)
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
    (4096, 64),
  ]
  for v in vectors {
    guard v.size <= 300000 else { continue }
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
test "random input splits and output sizes give the same output" {
  let rng = @fixtures.Rng::new(1951)
  for v in vectors {
    let input = v.input()
    for round in 0..<3 {
      let max_in = [1, 17, 1500][round]
      let max_out = [5000, 3, 70000][round]
      if v.size > 300000 && round != 2 {
        continue
      }
      let (got, _) = @fixtures.drive(
        Decoder(),
        input,
        next_in=() => 1 + rng.below(max_in),
        next_out=() => 1 + rng.below(max_out),
        step_into?=if round != 1 { Some(into) } else { None },
      )
      assert_eq(@fixtures.sha256(got), v.sha256, msg="\{v.name} round \{round}")
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
test "until=EndOfMember leaves what follows the final block, under every split" {
  let rest = b"what follows"
  for name in ["small_level6", "small_level0", "mixed_sync_flushed", "empty"] {
    let v = vector(name)
    let input = Bytes::from_array([..v.input(), ..rest])
    for split in [(1, 1), (3, 7), (1 << 20, 1 << 16), (64, 1)] {
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
      // Done again, consuming nothing.
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
  assert_eq(decoder.last_consumed(), stream.length())
  assert_true(decoder.is_finished())
  // More input, even empty, without end: still waiting.
  assert_true(decoder.step_into(b"", out, end=false) is NeedMoreInput)
  assert_true(decoder.step_into(b"", out, end=true) is Done)
  // After Done, any byte is trailing.
  assert_true(decoder.step_into(b"", out, end=true) is Done)
  let after = try decoder.step_into(b"x", out, end=true) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(after, TrailingData)
  // A byte after the final block, in a later step.
  let later = Decoder()
  let _ = later.step_into(stream, out, end=false)
  let kind = try later.step_into(b"\x00", out, end=true) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(kind, TrailingData)
  assert_eq(refusal(Bytes::from_array([..stream, 0])), TrailingData)
}

///|
test "errors stick until reset, and reset forgets the stream" {
  let stream = vector("small_level1").input()
  let decoder = Decoder()
  let out = FixedArray::make(64, b'\x00')
  let bad = b"\x07\x00"
  let first = try decoder.step_into(bad, out, end=true) catch {
    CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => "decoded"
  }
  inspect(first, content="Corrupt: reserved block type")
  assert_eq(decoder.last_consumed(), 0)
  assert_eq(decoder.last_produced(), 0)
  let again = try decoder.step_into(stream, out, end=true) catch {
    CodecError(kind, _) => Some(kind)
  } noraise {
    _ => None
  }
  assert_eq(again, Some(Corrupt))
  decoder.reset()
  let (got, _) = @fixtures.drive(decoder, stream, next_in=() => 100, next_out=() => {
    100
  })
  assert_eq(@fixtures.sha256(got), vector("small_level1").sha256)
  // Reset in the middle of a stream.
  decoder.reset()
  let _ = decoder.step_into(stream[:200], out, end=false)
  decoder.reset()
  let (got, _) = @fixtures.drive(decoder, stream, next_in=() => 7, next_out=() => {
    1000
  })
  assert_eq(@fixtures.sha256(got), vector("small_level1").sha256)
}

///|
test "the inflater's messages, without its prefix" {
  let message = (input : Bytes) => {
    try decompress(input) catch {
      CodecError(kind, message) => "\{Repr(kind)}: \{message}"
    } noraise {
      _ => "decoded"
    }
  }
  inspect(message(b""), content="Truncated: unexpected end of input")
  inspect(
    message(b"\x01\x05\x00\xfb\xff"),
    content="Corrupt: stored block length mismatch",
  )
}

///|
test "decompress honours max_output" {
  let v = vector("text_level6")
  let input = v.input()
  assert_eq(decompress(input, max_output=v.size).length(), v.size)
  let over = try decompress(input, max_output=v.size - 1) catch {
    CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => "decoded"
  }
  inspect(
    over,
    content="LimitExceeded({ resource: Output, needed: None, limit: 19999 }): the output exceeds 19999 bytes",
  )
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
