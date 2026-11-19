// Generated from parts/whole/whole_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
/// A step that copies input to output, at most `piece` bytes a step, and is
/// done one step after the input runs out (as decoders that see the end
/// only once they have room again).
fn copier(
  piece : Int32,
) -> (BytesView, MutArrayView[Byte]) -> (Int32, Int32, Bool) {
  let mut drained = false
  (rest, room) => {
    if rest.length() == 0 {
      let was = drained
      drained = true
      return (0, 0, was)
    }
    let n = rest.length().min(room.length()).min(piece)
    for i in 0..<n {
      room[i] = rest[i]
    }
    (n, n, false)
  }
}

///|
/// `step` as a decoder's step, which may raise.
fn decoding(
  step : (BytesView, MutArrayView[Byte]) -> (Int32, Int32, Bool),
) -> (BytesView, MutArrayView[Byte]) -> (Int32, Int32, Bool) raise @codec.CodecError {
  (rest, room) => step(rest, room)
}

///|
fn sample(n : Int32) -> Bytes {
  Bytes::makei(n, i => (i * 7 + i / 251).to_byte())
}

///|
test "decode and encode return all the output, across the array's growth" {
  for n in [0, 1, 4095, 4096, 4097, 16385, 100000] {
    let input = sample(n)
    for piece in [1 << 16, 1000] {
      let decoded = @whole.decode(input[:], decoding(copier(piece))) catch {
        _ => fail("\{n}: raised")
      }
      assert_eq(decoded, input)
      assert_eq(@whole.encode(input[:], copier(piece)), input)
    }
  }
}

///|
test "decode keeps to max_output, and raises one byte past it" {
  let input = sample(10000)
  assert_eq(
    @whole.decode(input[:], max_output=10000, decoding(copier(1 << 16))) catch {
      _ => fail("raised")
    },
    input,
  )
  for limit in [9999, 4096, 1, 0, -5] {
    let over = try
      @whole.decode(input[:], max_output=limit, decoding(copier(1000)))
    catch {
      CodecError(kind, message) => "\{Repr(kind)}: \{message}"
    } noraise {
      _ => "decoded"
    }
    let l = limit.max(0)
    assert_eq(
      over,
      "LimitExceeded({ resource: Output, needed: None, limit: \{l} }): the output exceeds \{l} bytes",
    )
  }
  // The largest limit is no limit, and an empty output is within any.
  assert_eq(
    @whole.decode(input[:], max_output=0x7FFFFFFF, decoding(copier(1000))) catch {
      _ => fail("raised")
    },
    input,
  )
  assert_eq(
    @whole.decode(b""[:], max_output=-1, decoding(copier(1))) catch {
      _ => fail("raised")
    },
    b"",
  )
}

///|
test "decode passes on what the step raises" {
  let got = try
    @whole.decode(b"abc"[:], (_, _) => {
      raise @codec.CodecError(Corrupt, "broken")
    })
  catch {
    CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => "decoded"
  }
  assert_eq(got, "Corrupt: broken")
}

///|
test "encode passes on what the step raises" {
  let got = try
    @whole.encode(b"abc"[:], (_, _) => {
      raise @codec.CodecError(Unsupported, "no")
    })
  catch {
    CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => "encoded"
  }
  assert_eq(got, "Unsupported: no")
}

///|
test "take hands out a full array as it is, and a copy of a part" {
  let full = FixedArray::makei(5, i => (i + 1).to_byte())
  assert_eq(@whole.take(full, 5), b"\x01\x02\x03\x04\x05")
  let part = FixedArray::makei(5, i => (i + 1).to_byte())
  assert_eq(@whole.take(part, 2), b"\x01\x02")
  assert_eq(@whole.take(part, 0), b"")
}

///|
/// What `decode` must give for an input of `n` bytes under `limit`: the
/// input when it fits, else the limit it reports.
fn expected(n : Int32, limit : Int32?) -> String {
  match limit {
    Some(l) if n > l.max(0) => "LimitExceeded \{l.max(0)}"
    _ => "decoded \{n}"
  }
}

///|
test "decode and encode hand back any input, and keep to any limit" {
  // An input of up to 20,000 bytes, fed up to 3,000 bytes a step, under no
  // limit or one from -1,000 to 21,000: around every growth of the array
  // and on both sides of the limit.
  @quickcheck.check(
    (c : (UInt16, UInt16, UInt16, Bool)) => {
      let n = c.0.to_int() % 20000
      let piece = c.1.to_int() % 3000 + 1
      let limit = if c.3 { Some(c.2.to_int() % 22000 - 1000) } else { None }
      let input = sample(n)
      let got = try
        @whole.decode(input[:], max_output?=limit, decoding(copier(piece)))
      catch {
        CodecError(LimitExceeded(l), _) => "LimitExceeded \{l.limit}"
        CodecError(kind, _) => "\{Repr(kind)}"
      } noraise {
        out => if out == input { "decoded \{n}" } else { "differs" }
      }
      got == expected(n, limit) &&
      @whole.encode(input[:], copier(piece)) == input
    },
    count=300,
    seed=2026,
  )
}
