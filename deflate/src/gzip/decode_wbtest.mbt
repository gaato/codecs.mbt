///|
test "every vector decodes to its original" {
  for v in vectors {
    let got = decompress(v.input())
    assert_eq(got.length(), v.size, msg=v.name)
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
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
      if in_chunk * out_chunk < 64 && (v.size > 20000 || input.length() > 20000) {
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
test "every proper prefix is truncated, or ends after a whole member" {
  for v in vectors {
    let input = v.input()
    guard input.length() <= 3000 else { continue }
    let whole = decompress(input)
    let mut members = 0
    for cut in 0..<input.length() {
      try decompress(input[:cut]) catch {
        CodecError(kind, _) =>
          assert_eq(kind, Truncated, msg="\{v.name} cut at \{cut}")
      } noraise {
        got => {
          assert_true(whole[:got.length()] == got[:], msg="\{v.name} at \{cut}")
          members += 1
        }
      }
    }
    if v.name.contains("members") || v.name.contains("member_between") {
      assert_true(members > 0, msg=v.name)
    }
  }
}

///|
test "headers: every field, as the bytes hold it" {
  let header = (name : String) => {
    let decoder = Decoder()
    let _ = @fixtures.drive(decoder, vector(name).input(), next_in=() => 1, next_out=() => {
      1 << 16
    })
    decoder.header()
  }
  debug_inspect(
    header("header_all"),
    content=(
      #|Some(
      #|  {
      #|    text: true,
      #|    mtime: 1700000000,
      #|    xfl: 0x02,
      #|    os: 0x03,
      #|    extra: Some(<Bytes: [0x78, 0x79, 0x02, 0x00, 0x7a, 0x7a]>),
      #|    name: Some(<Bytes: [0x61, 0x2e, 0x74, 0x78, 0x74]>),
      #|    comment: Some(<Bytes: [0x61, 0x6c, 0x6c, 0x20, 0x66, 0x69, 0x65, 0x6c, 0x64, 0x73]>),
      #|  },
      #|)
    ),
  )
  debug_inspect(
    header("header_latin1_name").map(h => h.name),
    content=(
      #|Some(Some(<Bytes: [0x63, 0x61, 0x66, 0xe9, 0x2e, 0x74, 0x78, 0x74]>))
    ),
  )
  debug_inspect(
    header("header_empty_extra").map(h => h.extra),
    content=(
      #|Some(Some(<Bytes: []>))
    ),
  )
  debug_inspect(
    header("gzip_level6"),
    content=(
      #|Some(
      #|  {
      #|    text: false,
      #|    mtime: 0,
      #|    xfl: 0x00,
      #|    os: 0x03,
      #|    extra: None,
      #|    name: None,
      #|    comment: None,
      #|  },
      #|)
    ),
  )
  debug_inspect(
    header("gzip_named").map(h => (h.mtime, h.name)),
    content=(
      #|Some(
      #|  (
      #|    1700000000,
      #|    Some(<Bytes: [0x70, 0x72, 0x6f, 0x73, 0x65, 0x2e, 0x74, 0x78, 0x74]>),
      #|  ),
      #|)
    ),
  )
}

///|
test "header() follows the members" {
  let a = vector("header_name").input()
  let b = vector("header_comment").input()
  let decoder = Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  assert_true(decoder.header() is None)
  // The first member's header, cut short: none yet.
  let _ = decoder.step_into(a[:12], out, end=false)
  assert_true(decoder.header() is None)
  let _ = decoder.step_into(a[12:], out, end=false)
  assert_true(decoder.header() is Some({ name: Some(_), .. }))
  // The second member's fixed part drops the first header.
  let _ = decoder.step_into(b[:10], out, end=false)
  assert_true(decoder.header() is None)
  assert_eq(decoder.memory_usage(), decoder.inner.memory_usage())
  assert_true(decoder.step_into(b[10:], out, end=true) is Done)
  assert_true(decoder.header() is Some({ comment: Some(_), name: None, .. }))
  decoder.reset()
  assert_true(decoder.header() is None)
}

///|
test "until=EndOfMember stops after the first member, under every split" {
  let first = vector("header_all").input()
  let second = vector("gzip_level1").input()
  let input = Bytes::from_array([..first, ..second])
  for split in [(1, 1), (3, 7), (1 << 20, 1 << 16), (64, 1)] {
    let (in_chunk, out_chunk) = split
    let decoder = Decoder(until=EndOfMember)
    let (got, consumed) = @fixtures.drive(
      decoder,
      input,
      next_in=() => in_chunk,
      next_out=() => out_chunk,
    )
    assert_eq(@fixtures.sha256(got), vector("header_all").sha256)
    assert_eq(consumed, first.length())
    assert_true(decoder.is_finished())
    let out = FixedArray::make(8, b'\x00')
    assert_true(decoder.step_into(second, out, end=true) is Done)
    assert_eq(decoder.last_consumed(), 0)
  }
}

///|
test "what may follow a member" {
  let stream = vector("small_level6").input()
  let after = (tail : Bytes) => {
    try decompress(Bytes::from_array([..stream, ..tail])) catch {
      CodecError(kind, _) => Repr(kind).to_string()
    } noraise {
      _ => "decoded"
    }
  }
  inspect(after(b""), content="decoded")
  // Zero padding, and anything that is not a magic number: trailing.
  inspect(after(b"\x00"), content="TrailingData")
  inspect(after(Bytes::make(512, b'\x00')), content="TrailingData")
  inspect(
    after(Bytes::from_array([..Bytes::make(4, b'\x00'), ..stream])),
    content="TrailingData",
  )
  inspect(after(b"garbage"), content="TrailingData")
  inspect(after(b"\x1f\x8c"), content="TrailingData")
  // The start of a magic number: a member cut short.
  inspect(after(b"\x1f"), content="Truncated")
  inspect(after(b"\x1f\x8b"), content="Truncated")
  inspect(after(b"\x1f\x8b\x08\x00"), content="Truncated")
  // A magic number, then no member: corrupt.
  inspect(after(b"\x1f\x8b\x07\x00\x00\x00\x00\x00\x00\x00"), content="Corrupt")
  // Without end, the decoder waits between members, then refuses a byte
  // that begins none.
  let decoder = Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  assert_true(decoder.step_into(stream, out, end=false) is NeedMoreInput)
  assert_false(decoder.is_finished())
  let kind = try decoder.step_into(b"\x00", out, end=false) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(kind, TrailingData)
  // After Done, anything is trailing.
  let done = Decoder()
  assert_true(done.step_into(stream, out, end=true) is Done)
  assert_true(done.step_into(b"", out, end=true) is Done)
  let kind = try done.step_into(stream, out, end=true) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(kind, TrailingData)
}

///|
/// A member with the header `header`, around a stored DEFLATE block of "x".
fn with_header(header : Bytes) -> Bytes {
  // A final stored block of "x", then CRC32("x") and ISIZE 1.
  let body = b"\x01\x01\x00\xfe\xffx\x83\x16\xdc\x8c\x01\x00\x00\x00"
  Bytes::from_array([..header, ..body])
}

///|
test "max_header_bytes bounds the extra field, the name and the comment together" {
  let fixed = (flags : Byte) => {
    Bytes::from_array([b'\x1f', b'\x8b', b'\x08', flags, 0, 0, 0, 0, 0, 0xff])
  }
  let limit = (input : Bytes, max : Int32) => {
    try
      @fixtures.drive(Decoder(max_header_bytes=max), input, next_in=() => 3, next_out=() => {
        100
      })
    catch {
      @codec.CodecError(LimitExceeded(limit), _) => Repr(limit).to_string()
      @codec.CodecError(kind, _) => Repr(kind).to_string()
      _ => "other"
    } noraise {
      (out, _) => "decoded \{out.length()}"
    }
  }
  let extra = (n : Int32) => {
    Bytes::from_array([n.to_byte(), (n >> 8).to_byte(), ..Bytes::make(n, b'e')])
  }
  let name = Bytes::from_array([..Bytes::make(100, b'n'), 0])
  // The extra field declares its size: refused at its length.
  inspect(
    limit(with_header(Bytes::from_array([..fixed(b'\x04'), ..extra(100)])), 99),
    content="{ resource: Memory, needed: Some(100), limit: 99 }",
  )
  inspect(
    limit(with_header(Bytes::from_array([..fixed(b'\x04'), ..extra(100)])), 100),
    content="decoded 1",
  )
  // A name or a comment declares none: refused when it passes the limit.
  inspect(
    limit(with_header(Bytes::from_array([..fixed(b'\x08'), ..name])), 99),
    content="{ resource: Memory, needed: None, limit: 99 }",
  )
  inspect(
    limit(
      with_header(
        Bytes::from_array([..fixed(b'\x1c'), ..extra(50), ..name, ..name]),
      ),
      250,
    ),
    content="decoded 1",
  )
  inspect(
    limit(
      with_header(
        Bytes::from_array([..fixed(b'\x1c'), ..extra(50), ..name, ..name]),
      ),
      249,
    ),
    content="{ resource: Memory, needed: None, limit: 249 }",
  )
  inspect(limit(with_header(fixed(b'\x00')), 0), content="decoded 1")
  inspect(limit(with_header(fixed(b'\x00')), -5), content="decoded 1")
  // A name with no end, as long as the input: refused, not held.
  let endless = Bytes::from_array(
    [..fixed(b'\x08'), ..Bytes::make(1 << 17, b'n')],
  )
  inspect(
    limit(endless, 65536),
    content="{ resource: Memory, needed: None, limit: 65536 }",
  )
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
  inspect(message(b""), content="Truncated: the input holds no member")
  inspect(
    message(b"\x1f\x8b\x08"),
    content="Truncated: the stream ends inside a member's header",
  )
  let stream = vector("small_level6").input()
  inspect(
    message(stream[:stream.length() - 3].to_owned()),
    content="Truncated: the stream ends inside a member's trailer",
  )
  inspect(
    message(b"PK\x03\x04\x00\x00\x00\x00\x00\x00"),
    content="Corrupt: not a gzip stream (the magic number is not 1f 8b)",
  )
  inspect(
    message(with_header(b"\x1f\x8b\x08\x02\x00\x00\x00\x00\x00\xff\x00\x00")),
    content="ChecksumMismatch: the header's CRC-16 (FHCRC) does not match the header",
  )
  let bad_size = with_header(b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff").to_array()
  bad_size[bad_size.length() - 4] = b'\x02'
  inspect(
    message(Bytes::from_array(bad_size)),
    content="ChecksumMismatch: the length of the data does not match the member's (ISIZE)",
  )
  // The step that raises took the start of the header; the steps after it
  // take nothing.
  let decoder = Decoder()
  let out = FixedArray::make(8, b'\x00')
  for consumed in [4, 0] {
    let kind = try
      decoder.step_into(b"\x1f\x8b\x09\x00", out, end=false)
    catch {
      CodecError(kind, _) => kind
    } noraise {
      _ => fail("decoded")
    }
    assert_eq(kind, Corrupt)
    assert_eq(decoder.last_consumed(), consumed)
    assert_eq(decoder.last_produced(), 0)
  }
  decoder.reset()
  let (got, _) = @fixtures.drive(decoder, stream, next_in=() => 50, next_out=() => {
    50
  })
  assert_eq(@fixtures.sha256(got), vector("small_level6").sha256)
}

///|
test "decompress honours max_output, over all members" {
  let v = vector("gzip_two_members")
  assert_eq(decompress(v.input(), max_output=v.size).length(), v.size)
  let over = try decompress(v.input(), max_output=v.size - 1) catch {
    CodecError(LimitExceeded(limit), _) => Some(limit)
    _ => None
  } noraise {
    _ => None
  }
  assert_eq(over, Some({ resource: Output, needed: None, limit: 8999, }))
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
