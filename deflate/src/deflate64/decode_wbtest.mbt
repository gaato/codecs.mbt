///|
fn[D : @codec_bytes.Decode] reset_through_contract(d : D) -> Unit raise {
  d.reset()
  assert_eq(d.last_consumed(), 0)
  assert_eq(d.last_produced(), 0)
  assert_eq(d.memory_usage(), decoder_memory_bound().to_int())
}

///|
test "Deflate64 memory bound" {
  assert_eq(Decoder().memory_usage(), decoder_memory_bound().to_int())
}

///|
test "Deflate64 truncation, trailing bytes, limits and both end policies" {
  let stream = fixed_match(b"a", 65538, 1)
  for cut in 0..<stream.length() {
    try decompress(stream[:cut]) catch {
      @codec.CodecError(Truncated, _) => ()
      err => fail("wrong truncation error: \{Repr(err)}")
    } noraise {
      _ => fail("proper prefix accepted")
    }
  }
  for limit in [-1, 0, 65538] {
    try decompress(stream, max_output=limit) catch {
      @codec.CodecError(LimitExceeded({ resource: Output, .. }), _) => ()
      err => fail("wrong limit error: \{Repr(err)}")
    } noraise {
      _ => fail("output limit ignored")
    }
  }
  assert_eq(decompress(stream, max_output=65539), Bytes::make(65539, b'a'))
  let out = FixedArray::make(1 << 17, b'\x00')
  let d = Decoder()
  assert_eq(d.step_into(stream, out, end=false), NeedMoreInput)
  assert_true(d.is_finished())
  assert_eq(d.last_produced(), 65539)
  assert_eq(d.step_into(b"", out, end=false), NeedMoreInput)
  try d.step_into(b"tail", out, end=true) catch {
    @codec.CodecError(TrailingData, _) => ()
    err => fail("wrong trailing error: \{Repr(err)}")
  } noraise {
    _ => fail("trailing bytes accepted")
  }
  assert_eq(d.last_consumed(), 0)
  try d.step_into(b"", out, end=true) catch {
    @codec.CodecError(TrailingData, _) => ()
    err => fail("error did not stick: \{Repr(err)}")
  } noraise {
    _ => fail("error did not stick")
  }
  assert_eq(d.last_produced(), 0)
  d.reset()
  assert_false(d.is_finished())
  assert_eq(d.step_into(b"\x03\x00", out, end=true), Done)
  assert_eq(d.step_into(b"", out, end=true), Done)
  assert_eq(d.last_produced(), 0)
  try d.step_into(b"tail", out, end=true) catch {
    @codec.CodecError(TrailingData, _) => ()
    err => fail("wrong post-Done error: \{Repr(err)}")
  } noraise {
    _ => fail("post-Done trailing bytes accepted")
  }
  try Decoder().step_into(stream + b"tail", out, end=true) catch {
    @codec.CodecError(TrailingData, _) => ()
    err => fail("wrong same-step trailing error: \{Repr(err)}")
  } noraise {
    _ => fail("same-step trailing bytes accepted")
  }
  let first = Decoder(until=EndOfMember)
  assert_eq(first.step_into(stream + b"next member", out, end=false), Done)
  assert_eq(first.last_consumed(), stream.length())
  assert_eq(first.last_produced(), 65539)
  assert_eq(first.step_into(b"untouched", out, end=true), Done)
  assert_eq(first.last_consumed(), 0)
}

///|
test "Deflate64 rejects invalid literal and distance entries and excessive HLIT" {
  let literal = BitWriter::new()
  literal.bits(3, 3)
  literal.fixed(286)
  literal.align()
  let counts = BitWriter::new()
  counts.bits(5, 3)
  counts.bits(31, 5)
  counts.bits(0, 5)
  counts.bits(0, 4)
  counts.align()
  let distance = BitWriter::new()
  distance.bits(5, 3)
  distance.bits(1, 5) // 258 literal/length symbols.
  distance.bits(0, 5) // One distance symbol.
  distance.bits(14, 4) // Include code-length symbols 0 and 1.
  for s in [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1] {
    distance.bits(if s == 0 || s == 1 { 1 } else { 0 }, 3)
  }
  for s in 0..<258 {
    distance.bits(if s >= 256 { 1 } else { 0 }, 1)
  }
  distance.bits(1, 1) // Distance symbol 0 has the lone one-bit code 0.
  distance.bits(1, 1) // Literal/length symbol 257.
  distance.bits(1, 1) // Unused distance code 1.
  distance.align()
  for
    (input, message) in [
      (literal.out.to_bytes(), "an invalid literal/length code"),
      (
        counts.out.to_bytes(),
        "a dynamic header counts more than 286 literal/length codes",
      ),
      (distance.out.to_bytes(), "an invalid distance code"),
    ] {
    try decompress(input) catch {
      @codec.CodecError(Corrupt, got) => assert_eq(got, message)
      err => fail("wrong malformed-code error: \{Repr(err)}")
    } noraise {
      _ => fail("malformed codes accepted")
    }
  }
}

///|
test "Deflate64 reset forgets a suspended long match and deferred errors drain first" {
  let stream = fixed_match(b"a", 65538, 1)
  let none = FixedArray::make(0, b'\x00')
  let d = Decoder()
  assert_eq(d.step_into(stream, none, end=true), NeedMoreOutput)
  reset_through_contract(d)
  let room = FixedArray::make(4096, b'\x00')
  assert_eq(d.step_into(b"\x03\x00", room, end=true), Done)
  assert_eq(d.last_produced(), 0)
  assert_eq(d.memory_usage(), decoder_memory_bound().to_int())
  let cut = stream[:stream.length() - 1].to_owned()
  let mut baseline : Bytes? = None
  for chunk in [1, 1 << 20] {
    for size in [7, 1 << 17] {
      let d = Decoder()
      let out = FixedArray::make(size, b'\x00')
      let got = Buffer()
      let mut pos = 0
      let mut pending = cut[0:0]
      for ;; {
        if pending.length() == 0 && pos < cut.length() {
          let end = (pos + chunk).min(cut.length())
          pending = cut[pos:end]
          pos = end
        }
        let status = d.step_into(pending, out, end=pos == cut.length()) catch {
          @codec.CodecError(Truncated, _) => {
            got.write_bytes(Bytes::from_array(out[:d.last_produced()]))
            break
          }
          err => fail("wrong deferred error: \{Repr(err)}")
        }
        pending = pending[d.last_consumed():]
        got.write_bytes(Bytes::from_array(out[:d.last_produced()]))
        assert_false(status is Done)
      }
      let bytes = got.to_bytes()
      assert_eq(bytes.length(), 65539)
      match baseline {
        None => baseline = Some(bytes)
        Some(b) => assert_true(bytes == b)
      }
      assert_eq(d.memory_usage(), decoder_memory_bound().to_int())
    }
  }
}
