///|
/// The vector named `name`.
fn vector(name : String) -> Vector {
  vectors[vectors.search_by(v => v.name == name).unwrap()]
}

///|
/// The kind of error `decompress` raises on `input`.
fn refusal(
  input : BytesView,
  max_window_bits~ : Int32 = 27,
) -> @codec.ErrorKind raise {
  try decompress(input, max_window_bits~) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
}

///|
test "every vector decodes to its original" {
  for v in vectors {
    let got = decompress(v.input(), max_window_bits=v.window_bits)
    assert_eq(got.length(), v.size, msg=v.name)
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "upstream corrupt frames are refused" {
  for case in corrupt_vectors {
    let (name, compressed) = case
    let input = @base64.decode(compressed, ignore_whitespace=true)
    assert_eq(refusal(input), Corrupt, msg=name)
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
    // Byte-sized steps over the MiB vectors would only add run time.
    guard v.size <= 300000 else { continue }
    let input = v.input()
    for split in splits {
      let (in_chunk, out_chunk) = split
      if in_chunk * out_chunk < 64 && v.size > 20000 {
        continue
      }
      let got = drive(
        Decoder(max_window_bits=v.window_bits),
        input,
        next_in=() => in_chunk,
        next_out=() => out_chunk,
      )
      assert_eq(
        @checksum.sha256(got),
        v.sha256,
        msg="\{v.name} in \{in_chunk} out \{out_chunk}",
      )
    }
  }
}

///|
test "random input splits and output sizes give the same output" {
  let rng = Rng::new(8878)
  for v in vectors {
    let input = v.input()
    for round in 0..<3 {
      let max_in = [1, 17, 1500][round]
      let max_out = [5000, 3, 70000][round]
      // One-byte input steps over the MiB vectors would only add run time.
      if v.size > 300000 && round != 2 {
        continue
      }
      let got = drive(
        Decoder(max_window_bits=v.window_bits),
        input,
        next_in=() => 1 + rng.below(max_in),
        next_out=() => 1 + rng.below(max_out),
        fixed=round != 1,
      )
      assert_eq(@checksum.sha256(got), v.sha256, msg="\{v.name} round \{round}")
    }
  }
}

///|
test "every proper prefix is truncated, or ends after a whole frame" {
  for v in vectors {
    let input = v.input()
    guard input.length() <= 3000 else { continue }
    let whole = decompress(input, max_window_bits=v.window_bits)
    let mut frames = 0
    for cut in 0..<input.length() {
      try decompress(input[:cut], max_window_bits=v.window_bits) catch {
        CodecError(kind, _) =>
          assert_eq(kind, Truncated, msg="\{v.name} cut at \{cut}")
      } noraise {
        got => {
          // A cut between frames: what came before it decodes.
          assert_true(
            whole[:got.length()] == got[:],
            msg="\{v.name} cut at \{cut}",
          )
          frames += 1
        }
      }
    }
    if v.name is ("gen/two_frames" | "gen/skippable_between") {
      assert_true(frames > 0, msg=v.name)
    }
  }
}

///|
test "an empty stream or a few stray bytes are truncated" {
  let one = vector("gen/one_byte").input()
  debug_inspect(refusal(b""), content="Truncated")
  for n in 1..<=3 {
    let stray = Bytes::from_array([..one[:], ..one[:n]])
    debug_inspect(refusal(stray), content="Truncated")
  }
  let messages = []
  for input in [b""[:], one[:3]] {
    try decompress(input) catch {
      CodecError(_, message) => messages.push(message)
    } noraise {
      _ => fail("decoded")
    }
  }
  debug_inspect(
    messages,
    content=(
      #|["the stream holds no frame", "the stream ends inside a frame"]
    ),
  )
}

///|
test "bytes after the last frame are refused, in the same step or a later one" {
  let one = vector("gen/one_byte").input()
  debug_inspect(refusal(b"\x00\x00\x00\x00"), content="Corrupt")
  let junk = Bytes::from_array([..one[:], ..b"junk"])
  debug_inspect(refusal(junk), content="TrailingData")
  let decoder = Decoder()
  let out = FixedArray::make(8, b'\x00')
  debug_inspect(decoder.step_into(one, out, end=false), content="NeedMoreInput")
  inspect(decoder.last_produced(), content="1")
  assert_false(decoder.is_finished())
  // Between frames the decoder waits; `end` closes the stream.
  debug_inspect(decoder.step_into(b"", out, end=true), content="Done")
  assert_true(decoder.is_finished())
  debug_inspect(decoder.step_into(b"", out, end=false), content="Done")
  let late = try decoder.step_into(b"\x00", out, end=false) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("trailing byte accepted")
  }
  debug_inspect(late, content="TrailingData")
  // The error sticks until `reset`.
  let again = try decoder.step_into(b"", out, end=false) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("error forgotten")
  }
  debug_inspect(again, content="TrailingData")
  inspect(decoder.last_consumed(), content="0")
  inspect(decoder.last_produced(), content="0")
  decoder.reset()
  debug_inspect(decoder.step_into(one, out, end=true), content="Done")
}

///|
test "a decoder is reused across streams after reset" {
  let decoder = Decoder(max_window_bits=30)
  for v in vectors {
    guard v.size <= 300000 else { continue }
    decoder.reset()
    let got = drive(decoder, v.input(), next_in=() => 999, next_out=() => 4096)
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "decompress honours max_output" {
  let v = vector("gen/text_level3")
  let input = v.input()
  inspect(decompress(input, max_output=v.size).length(), content="60000")
  let refused = try decompress(input, max_output=v.size - 1) catch {
    CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => fail("limit ignored")
  }
  inspect(
    refused,
    content=(
      #|LimitExceeded({ resource: Output, needed: None, limit: 59999 }): the output exceeds 59999 bytes
    ),
  )
}

///|
test "max_window_bits refuses larger windows and is clamped" {
  for v in vectors {
    guard v.window_bits > 10 else { continue }
    // The window needed is over the limit, and fits the next power of two.
    let limit = 1UL << (v.window_bits - 1)
    let kind = refusal(v.input(), max_window_bits=v.window_bits - 1)
    guard kind
      is LimitExceeded({ resource: Memory, needed: Some(n), limit: l, }) &&
      l == limit &&
      n > limit &&
      n <= limit * 2 else {
      fail("\{v.name}: \{Repr(kind)}")
    }
  }
  // The default limit is 27; 99 is clamped to 30, and 3 to 10.
  let v = vector("gen/window30_declared")
  debug_inspect(
    refusal(v.input()),
    content=(
      #|LimitExceeded({ resource: Memory, needed: Some(1073741824), limit: 134217728 })
    ),
  )
  assert_eq(decompress(v.input(), max_window_bits=99).length(), v.size)
  let v = vector("gen/window27_declared")
  assert_eq(decompress(v.input()).length(), v.size)
  let v = vector("gen/window10_text")
  assert_eq(decompress(v.input(), max_window_bits=3).length(), v.size)
  let refused = try
    decompress(vector("gen/text_level3").input(), max_window_bits=3)
  catch {
    CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => fail("decoded")
  }
  inspect(
    refused,
    content=(
      #|LimitExceeded({ resource: Memory, needed: Some(60000), limit: 1024 }): the frame needs a 60000-byte window, over the 1024-byte limit
    ),
  )
}

///|
/// The kind `step_into` raises on `input`, with `end`.
fn step_refusal(
  decoder : Decoder,
  input : BytesView,
  end~ : Bool,
) -> @codec.ErrorKind raise {
  try decoder.step_into(input, FixedArray::make(64, b'\x00'), end~) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
}

///|
test "until=EndOfMember stops after the first frame and leaves the rest" {
  let first = vector("gen/one_byte").input()
  let second = vector("gen/text_200").input()
  let both = Bytes::from_array([..first[:], ..second[:]])
  // Whole input, with and without `end`: Done at the frame's end.
  for end in [false, true] {
    let decoder = Decoder(until=EndOfMember)
    let out = FixedArray::make(64, b'\x00')
    debug_inspect(decoder.step_into(both, out, end~), content="Done")
    assert_eq(decoder.last_consumed(), first.length())
    assert_eq(
      Bytes::from_array(out[:decoder.last_produced()]),
      decompress(first),
    )
    assert_true(decoder.is_finished())
    // The stream is over: nothing more is taken, and nothing is refused.
    debug_inspect(decoder.step_into(second, out, end~), content="Done")
    inspect(decoder.last_consumed(), content="0")
    inspect(decoder.last_produced(), content="0")
    // `reset` keeps the option: the rest is the next stream.
    decoder.reset()
    debug_inspect(
      decoder.step_into(second, out, end=true),
      content="NeedMoreOutput",
    )
    assert_eq(decoder.last_consumed(), second.length())
  }
  // A byte at a time, into one byte of room: the frame ends at the same
  // place.
  let decoder = Decoder(until=EndOfMember)
  let out = FixedArray::make(1, b'\x00')
  let got = Buffer()
  let mut taken = 0
  for ;; {
    let chunk = both[taken:(taken + 1).min(both.length())]
    let status = decoder.step_into(chunk, out, end=false)
    taken += decoder.last_consumed()
    got.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
    if status is Done {
      break
    }
  }
  assert_eq(taken, first.length())
  assert_eq(got.to_bytes(), decompress(first))
}

///|
test "until=EndOfMember counts a skippable frame as a frame" {
  let input = vector("gen/skippable_first").input()
  let decoder = Decoder(until=EndOfMember)
  let out = FixedArray::make(64, b'\x00')
  debug_inspect(decoder.step_into(input, out, end=false), content="Done")
  // The magic number, the size, and one byte of user data.
  inspect(decoder.last_consumed(), content="9")
  inspect(decoder.last_produced(), content="0")
  // The frame after it is a stream of its own.
  let rest = input[decoder.last_consumed():]
  assert_eq(decompress(rest).length(), 5000)
}

///|
test "until=EndOfMember: a first frame cut short is truncated" {
  let input = vector("gen/text_200").input()
  for cut in [0, 2, 4, 10, input.length() - 1] {
    let decoder = Decoder(until=EndOfMember)
    let kind = step_refusal(decoder, input[:cut], end=true)
    assert_eq(kind, Truncated, msg="cut at \{cut}")
  }
  // Without `end`, the decoder waits for the rest.
  let decoder = Decoder(until=EndOfMember)
  let out = FixedArray::make(64, b'\x00')
  let half = input.length() / 2
  debug_inspect(
    decoder.step_into(input[:half], out, end=false),
    content="NeedMoreInput",
  )
  debug_inspect(
    decoder.step_into(input[half:], FixedArray::make(256, b'\x00'), end=true),
    content="Done",
  )
}

///|
test "after the last frame: TrailingData, Truncated, or Corrupt before any frame" {
  let one = vector("gen/one_byte").input()
  let skip = vector("gen/skippable_only").input()
  let after = (head : Bytes, tail : Bytes) => {
    let kind = refusal(Bytes::from_array([..head[:], ..tail[:]]))
    Repr(kind).to_string()
  }
  // Four bytes that start no frame follow a frame, or a skippable frame.
  inspect(after(one, b"\x00\x00\x00\x00"), content="TrailingData")
  inspect(
    after(one, b"\xff\xff\xff\xff\xff\xff\xff\xff"),
    content="TrailingData",
  )
  inspect(after(skip, b"junk"), content="TrailingData")
  // Fewer than four bytes, or the start of another frame, are cut short.
  inspect(after(one, b"\x28\xb5\x2f"), content="Truncated")
  inspect(after(one, b"\x28\xb5\x2f\xfd"), content="Truncated")
  inspect(after(one, b"\x50\x2a\x4d\x18\x01"), content="Truncated")
  // With no frame before them, the same bytes are not a zstd stream.
  inspect(after(b"", b"\x00\x00\x00\x00"), content="Corrupt")
  inspect(after(b"", b"junk"), content="Corrupt")
  // Split anywhere, trailing bytes give the same error, and it sticks.
  let input = Bytes::from_array([..one[:], ..b"junk"])
  for cut in 0..<input.length() {
    let decoder = Decoder()
    let out = FixedArray::make(8, b'\x00')
    let kind = try {
      ignore(decoder.step_into(input[:cut], out, end=false))
      decoder.step_into(input[cut:], out, end=true)
    } catch {
      CodecError(kind, _) => kind
    } noraise {
      _ => fail("decoded")
    }
    assert_eq(kind, TrailingData, msg="cut at \{cut}")
    assert_eq(step_refusal(decoder, b"", end=true), TrailingData)
  }
}

///|
test "a frame that names a dictionary carries its id" {
  let frame = b"\x28\xb5\x2f\xfd\x02\x00\x34\x12\x01\x00\x00"
  debug_inspect(refusal(frame), content="DictionaryRequired(Some(4660))")
  let decoder = Decoder()
  guard step_refusal(decoder, frame, end=false) is DictionaryRequired(Some(id)) else {
    fail("no dictionary id")
  }
  inspect(id, content="4660")
}
