///|
/// Decodes `input` under `EndOfMember` in chunks of `next_in()` bytes into
/// slices of `next_out()` bytes, with `end` once the last chunk is handed
/// over, checking the bounds after every step. Returns the output and the
/// input the decoder left unread when it answered `Done`.
fn drive_member(
  input : Bytes,
  next_in~ : () -> Int32,
  next_out~ : () -> Int32,
) -> (Bytes, Bytes) raise {
  let decoder = Decoder(until=EndOfMember)
  let out = Buffer()
  let mut pos = 0
  let mut pending = input[0:0]
  for ;; {
    if pending.length() == 0 && pos < input.length() {
      let next = (pos + next_in()).min(input.length())
      pending = input[pos:next]
      pos = next
    }
    let end = pos == input.length()
    let buffer = FixedArray::make(next_out(), b'\x00')
    let status = decoder.step_into(pending, buffer, end~)
    check_bounds(decoder, buffer.length())
    pending = pending[decoder.last_consumed():]
    out.write_bytesview(Bytes::from_array(buffer[:decoder.last_produced()])[:])
    match status {
      Done =>
        return (out.to_bytes(), pending.to_owned() + input[pos:].to_owned())
      NeedMoreInput => {
        assert_eq(pending.length(), 0)
        assert_false(end)
      }
      NeedMoreOutput => ()
    }
  }
}

///|
test "EndOfMember stops right after the stream and leaves what follows" {
  let rng = Rng::new(9841)
  let streams = vectors
    .filter(v => v.size <= 300000)
    .map(v => (v.name, v.input(), v.sha256))
  for sample in [b"", b"x", sample_text(rng, 100000), sample_random(rng, 70000)] {
    // Ending in a compressed, an uncompressed and an empty last meta-block.
    streams.push(("compress", compress(sample), @checksum.sha256(sample)))
  }
  let tails : Array[Bytes] = [
    b"",
    b"\x00",
    b"\xff\xff\xff",
    b"\x06",
    compress(b"next"),
  ]
  for s in streams {
    let (name, stream, sha256) = s
    for tail in tails {
      let input = stream + tail
      let splits : Array[(() -> Int32, () -> Int32)] = [
        (() => 1 << 20, () => 1 << 16),
        (() => 3, () => 4096),
        (() => 1 + rng.below(50), () => 1 + rng.below(3000)),
      ]
      if stream.length() <= 4000 {
        splits.push((() => 1, () => 1))
      }
      for split in splits {
        let (next_in, next_out) = split
        let (output, rest) = drive_member(input, next_in~, next_out~)
        assert_eq(@checksum.sha256(output), sha256, msg=name)
        assert_true(rest == tail, msg="\{name}: \{rest} left, not \{tail}")
      }
    }
  }
}

///|
test "EndOfMember reports a cut stream as Truncated, and asks for more without end" {
  for v in vectors {
    let input = v.input()
    guard input.length() <= 2000 else { continue }
    for cut in 0..<input.length() {
      let decoder = Decoder(until=EndOfMember)
      let out = FixedArray::make(1 << 20, b'\x00')
      debug_inspect(
        decoder.step_into(input[:cut], out, end=false),
        content="NeedMoreInput",
      )
      let decoder = Decoder(until=EndOfMember)
      let outcome = try decoder.step_into(input[:cut], out, end=true) catch {
        @codec.CodecError(kind, _) => kind
      } noraise {
        status => fail("\{v.name} cut at \{cut}: \{Repr(status)}")
      }
      assert_eq(outcome, Truncated, msg="\{v.name} cut at \{cut}")
    }
  }
}

///|
test "after EndOfMember's Done, steps take nothing and answer Done" {
  let decoder = Decoder(until=EndOfMember)
  let out = FixedArray::make(64, b'\x00')
  let stream = compress(b"hello")
  // Output that waits for room is handed out first.
  let input = stream + b"rest"
  debug_inspect(
    decoder.step_into(input, FixedArray::make(2, b'\x00'), end=false),
    content="NeedMoreOutput",
  )
  let consumed = decoder.last_consumed()
  assert_true(consumed <= stream.length())
  debug_inspect(
    decoder.step_into(input[consumed:], out, end=false),
    content="Done",
  )
  inspect(decoder.last_produced(), content="3")
  assert_eq(consumed + decoder.last_consumed(), stream.length())
  debug_inspect(decoder.step_into(b"rest", out, end=true), content="Done")
  inspect(decoder.last_consumed(), content="0")
  inspect(decoder.last_produced(), content="0")
  // The empty stream: ISLAST and ISLASTEMPTY, then padding.
  decoder.reset()
  debug_inspect(decoder.step_into(b"\x06\x06", out, end=true), content="Done")
  inspect(decoder.last_consumed(), content="1")
}
