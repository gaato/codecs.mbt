///|
test "every vector decodes to its original" {
  for v in vectors {
    let got = decompress(v.input())
    assert_eq(got.length(), v.size, msg=v.name)
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
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
    // Byte-sized steps over the 5 MiB vector would only add run time.
    guard v.size <= 300000 else { continue }
    let input = v.input()
    for split in splits {
      let (in_chunk, out_chunk) = split
      if in_chunk * out_chunk < 64 && v.size > 20000 {
        continue
      }
      let got = stream(input, in_chunk~, out_chunk~)
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
  let rng = Rng::new(7932)
  for v in vectors {
    let input = v.input()
    for round in 0..<3 {
      let max_in = [1, 17, 1500][round]
      let max_out = [5000, 3, 70000][round]
      let got = drive(
        Decoder(),
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
test "every proper prefix of a stream is truncated" {
  for v in vectors {
    let input = v.input()
    guard input.length() <= 2000 else { continue }
    for cut in 0..<input.length() {
      let outcome = try decompress(input[:cut]) catch {
        @codec.CodecError(kind, _) => kind
      } noraise {
        _ => fail("\{v.name} cut at \{cut} decoded")
      }
      assert_eq(outcome, Truncated, msg="\{v.name} cut at \{cut}")
    }
  }
}

///|
test "bytes after the end are refused in the same step or a later one" {
  let input = b"\x06"
  let decoder = Decoder()
  let out = FixedArray::make(8, b'\x00')
  // The stream is over, but without `end` more bytes may still come.
  debug_inspect(
    decoder.step_into(input, out, end=false),
    content="NeedMoreInput",
  )
  assert_true(decoder.is_finished())
  // An empty step after the end is fine; a byte is not.
  debug_inspect(decoder.step_into(b"", out, end=true), content="Done")
  let late = try decoder.step_into(b"\x00", out, end=false) catch {
    @codec.CodecError(kind, _) => kind
  } noraise {
    _ => fail("trailing byte accepted")
  }
  debug_inspect(late, content="TrailingData")
  // The error sticks until `reset`.
  let again = try decoder.step_into(b"", out, end=true) catch {
    @codec.CodecError(kind, _) => kind
  } noraise {
    _ => fail("error forgotten")
  }
  debug_inspect(again, content="TrailingData")
  inspect(decoder.last_consumed(), content="0")
  inspect(decoder.last_produced(), content="0")
  decoder.reset()
  debug_inspect(decoder.step_into(input, out, end=true), content="Done")
}

///|
test "a decoder is reused across streams after reset" {
  let decoder = Decoder()
  for v in vectors {
    guard v.size <= 300000 else { continue }
    decoder.reset()
    let got = drive(decoder, v.input(), next_in=() => 999, next_out=() => 4096)
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "decompress honours max_output" {
  let alice = vectors
    .search_by(v => v.name == "alice29.txt.compressed")
    .unwrap()
  let input = vectors[alice].input()
  inspect(decompress(input, max_output=152089).length(), content="152089")
  let refused = try decompress(input, max_output=152088) catch {
    @codec.CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => fail("limit ignored")
  }
  inspect(
    refused,
    content="LimitExceeded({ resource: Output, needed: None, limit: 152088 }): the output exceeds 152088 bytes",
  )
}

///|
test "max_window_bits refuses larger windows and is clamped" {
  let far = vectors.search_by(v => v.name == "gen/window24_far").unwrap()
  let input = vectors[far].input()
  // The window the stream needs and the largest one allowed, in bytes.
  for bits in [10, 23] {
    let refused = try decompress(input, max_window_bits=bits) catch {
      @codec.CodecError(kind, _) => kind
    } noraise {
      _ => fail("window over \{bits} bits accepted")
    }
    assert_eq(
      refused,
      LimitExceeded({
        resource: Memory,
        needed: Some((1UL << 24) - 16),
        limit: (1UL << bits) - 16,
      }),
    )
  }
  assert_eq(decompress(input, max_window_bits=99).length(), vectors[far].size)
  // A 16-bit window passes a limit of 16 (and of 3, clamped up to 10, fails).
  let small = BitWriter::new().bits(1, 0).bits(2, 3).finish()
  inspect(decompress(small, max_window_bits=16).length(), content="0")
  let clamped = try decompress(small, max_window_bits=3) catch {
    @codec.CodecError(kind, _) => kind
  } noraise {
    _ => fail("16-bit window under a 10-bit limit accepted")
  }
  debug_inspect(
    clamped,
    content="LimitExceeded({ resource: Memory, needed: Some(65520), limit: 1008 })",
  )
}

///|
/// Steps a fresh decoder over `input`, given whole with `end`, into `room`
/// bytes at a time, until it finishes or raises: the output, the input
/// consumed, and the error, if any.
fn run_to_error(
  input : BytesView,
  room : Int32,
) -> (Bytes, Int32, @codec.ErrorKind?) raise {
  let decoder = Decoder()
  let out = FixedArray::make(room, b'\x00')
  let got = Buffer()
  let mut taken = 0
  for ;; {
    let (status, error) = try
      decoder.step_into(input[taken:], out, end=true)
    catch {
      @codec.CodecError(kind, _) => (None, Some(kind))
    } noraise {
      status => (Some(status), None)
    }
    taken += decoder.last_consumed()
    got.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
    if error is Some(kind) {
      // The error sticks, and the steps after it take and give nothing.
      let again = try decoder.step_into(b"junk", out, end=true) catch {
        @codec.CodecError(next, _) => next
      } noraise {
        _ => fail("error forgotten")
      }
      assert_eq(again, kind)
      assert_eq(decoder.last_consumed(), 0)
      assert_eq(decoder.last_produced(), 0)
      return (got.to_bytes(), taken, error)
    }
    match status {
      Some(NeedMoreOutput) => continue
      Some(Done) => return (got.to_bytes(), taken, None)
      _ => fail("NeedMoreInput after the end")
    }
  }
}

///|
test "a step that raises hands out the output before the error and reports it" {
  let alice = vectors
    .search_by(v => v.name == "alice29.txt.compressed")
    .unwrap()
  let input = vectors[alice].input()
  let expected = decompress(input)
  // Bytes after the stream: everything decoded, the stream consumed to its
  // end exactly (the bytes read ahead given back), then TrailingData.
  let junk = Bytes::from_array([..input[:], ..b"junk"])
  for room in [1 << 18, 1000, 1] {
    let (got, taken, error) = run_to_error(junk, room)
    debug_inspect(error, content="Some(TrailingData)")
    assert_eq(taken, input.length(), msg="room \{room}")
    assert_eq(got, expected, msg="room \{room}")
  }
  // Cut short, or bytes changed: the same output and error whatever the
  // room.
  let cut = input[:input.length() / 2]
  let (whole, _, error) = run_to_error(cut, 1 << 18)
  debug_inspect(error, content="Some(Truncated)")
  assert_true(whole.length() > 0)
  let (small, _, again) = run_to_error(cut, 7)
  assert_eq(again, error)
  assert_eq(small, whole)
  for at in [100, input.length() / 2, input.length() - 10] {
    let bad = input.to_array()
    bad[at] = bad[at] ^ 0x5a
    let (whole, _, error) = run_to_error(Bytes::from_array(bad), 1 << 18)
    let (small, _, again) = run_to_error(Bytes::from_array(bad), 7)
    assert_eq(again, error, msg="byte \{at}")
    assert_eq(small, whole, msg="byte \{at}")
  }
}
