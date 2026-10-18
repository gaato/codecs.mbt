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
) -> ZstdErrorKind raise {
  try decompress(input, max_window_bits~) catch {
    ZstdError(kind, _) => kind
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
        ZstdError(kind, _) =>
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
      ZstdError(_, message) => messages.push(message)
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
  debug_inspect(refusal(junk), content="Corrupt")
  let decoder = Decoder()
  let out = FixedArray::make(8, b'\x00')
  debug_inspect(decoder.step_into(one, out), content="NeedMoreInput")
  inspect(decoder.last_produced(), content="1")
  assert_false(decoder.is_finished())
  // Between frames the decoder waits; `end` closes the stream.
  debug_inspect(decoder.step_into(b"", out, end=true), content="Done")
  assert_true(decoder.is_finished())
  debug_inspect(decoder.step_into(b"", out), content="Done")
  let late = try decoder.step_into(b"\x00", out) catch {
    ZstdError(kind, _) => kind
  } noraise {
    _ => fail("trailing byte accepted")
  }
  debug_inspect(late, content="Corrupt")
  // The error sticks until `reset`.
  let again = try decoder.step_into(b"", out) catch {
    ZstdError(kind, _) => kind
  } noraise {
    _ => fail("error forgotten")
  }
  debug_inspect(again, content="Corrupt")
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
    ZstdError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => fail("limit ignored")
  }
  inspect(
    refused,
    content="OutputLimitExceeded: the output exceeds 59999 bytes",
  )
}

///|
test "max_window_bits refuses larger windows and is clamped" {
  for v in vectors {
    guard v.window_bits > 10 else { continue }
    assert_eq(
      refusal(v.input(), max_window_bits=v.window_bits - 1),
      WindowTooLarge,
      msg=v.name,
    )
  }
  // The default limit is 27; 99 is clamped to 30, and 3 to 10.
  let v = vector("gen/window30_declared")
  debug_inspect(refusal(v.input()), content="WindowTooLarge")
  assert_eq(decompress(v.input(), max_window_bits=99).length(), v.size)
  let v = vector("gen/window27_declared")
  assert_eq(decompress(v.input()).length(), v.size)
  let v = vector("gen/window10_text")
  assert_eq(decompress(v.input(), max_window_bits=3).length(), v.size)
  let refused = try
    decompress(vector("gen/text_level3").input(), max_window_bits=3)
  catch {
    ZstdError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => fail("decoded")
  }
  inspect(
    refused,
    content="WindowTooLarge: the frame needs a 60000-byte window, over the 1024-byte limit",
  )
}
