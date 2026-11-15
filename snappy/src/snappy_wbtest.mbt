///|
fn sample(n : Int32, seed : UInt64, text~ : Bool) -> Bytes {
  let words = ["snappy ", "frame ", "chunk ", "copy ", "literal ", "the ", "a "]
  let mut state = seed
  let next = (bound : Int32) => {
    state = state * 6364136223846793005UL + 1442695040888963407UL
    ((state >> 33) % bound.to_uint64()).to_int()
  }
  if !text {
    return Bytes::makei(n, _ => next(256).to_byte())
  }
  let out = Buffer()
  while out.length() < n {
    out.write_string_utf8(words[next(words.length())])
  }
  out.to_bytes()[:n].to_owned()
}

///|
fn error_kind(f : () -> Unit raise @codec.CodecError) -> String {
  try f() catch {
    @codec.CodecError(kind, _) => return "\{Repr(kind)}"
  } noraise {
    _ => "ok"
  }
}

///|
fn inputs() -> Array[Bytes] {
  [
    b"",
    b"a",
    b"abcdefghijklmn",
    Bytes::make(100000, b'z'),
    sample(1000, 1, text=true),
    sample(65536, 2, text=true),
    sample(65537, 3, text=true),
    sample(300000, 4, text=true),
    sample(70000, 5, text=false),
  ]
}

///|
test "raw streams round-trip and stay within the bound" {
  for input in inputs() {
    let raw = compress_raw(input)
    assert_true(
      raw.length().to_int64() <= raw_compress_bound(input.length().to_int64()),
    )
    assert_true(decompress_raw(raw) == input)
  }
  inspect(compress_raw(b""), content="b\"\\x00\"")
}

///|
test "raw streams that break the format are refused" {
  let cases : Array[(Bytes, String)] = [
    (b"", "Truncated"),
    (b"\x80\x80\x80\x80\x80\x01", "Corrupt"),
    (b"\xff\xff\xff\xff\x10", "Corrupt"),
    // A literal of 3 bytes with 2 given.
    (b"\x03\x08ab", "Corrupt"),
    // A copy of 4 bytes with offset 0, and one from before the start.
    (b"\x05\x00a\x01\x00", "Corrupt"),
    (b"\x05\x00a\x01\x02", "Corrupt"),
    // A length of 2 with 1 byte decoded.
    (b"\x02\x00a", "Corrupt"),
    // A copy past the length.
    (b"\x03\x00a\x01\x01", "Corrupt"),
    // A length the bytes cannot make.
    (b"\xff\xff\x7f\x00a", "Corrupt"),
    // A literal whose length byte is missing, and copies whose offsets are
    // cut short: one byte of none, two of one, four of two.
    (b"\x05\xf0", "Corrupt"),
    (b"\x05\x00a\x01", "Corrupt"),
    (b"\x05\x00a\x02\x01", "Corrupt"),
    (b"\x05\x00a\x0f\x01\x00", "Corrupt"),
  ]
  for c in cases {
    let (stream, kind) = c
    assert_eq(
      error_kind(() => decompress_raw(stream) |> ignore),
      kind,
      msg="\{stream}",
    )
  }
  let stream = compress_raw(Bytes::make(1000, b'q'))
  assert_eq(
    error_kind(() => decompress_raw(stream, max_output=999) |> ignore),
    "LimitExceeded({ resource: Output, needed: Some(1000), limit: 999 })",
  )
  assert_eq(decompress_raw(stream, max_output=1000).length(), 1000)
}

///|
/// Encodes `input` in steps of `piece` input bytes into slices of `room`,
/// flushing when `flush` says.
fn encode_split(
  input : Bytes,
  piece : Int32,
  room : Int32,
  flush~ : (Int32) -> Bool = _ => false,
) -> Bytes {
  let e = Encoder()
  let out = Buffer()
  let slice = FixedArray::make(room, b'\x00')
  let mut pos = 0
  for ;; {
    let end = (pos + piece).min(input.length())
    let action : @codec_bytes.EncodeAction = if end == input.length() {
      Finish
    } else if flush(end) {
      Flush
    } else {
      Continue
    }
    let mut rest = input[pos:end]
    for ;; {
      let status = e.step(rest, slice.mut_view(), action~)
      rest = rest[e.last_consumed():]
      out.write_bytesview(Bytes::from_array(slice[:e.last_produced()])[:])
      match status {
        Done => return out.to_bytes()
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
    pos = end
  }
}

///|
/// Decodes `stream` in pieces of `piece` into slices of `room`.
fn decode_split(
  stream : Bytes,
  piece : Int32,
  room : Int32,
  until~ : @codec_bytes.Until = EndOfInput,
) -> (Bytes, Int32) raise @codec.CodecError {
  let d = Decoder(until~)
  let out = Buffer()
  let slice = FixedArray::make(room, b'\x00')
  let mut pos = 0
  for ;; {
    let end = (pos + piece).min(stream.length())
    let mut rest = stream[pos:end]
    for ;; {
      let status = d.step(rest, slice.mut_view(), end=end == stream.length())
      let used = d.last_consumed()
      rest = rest[used:]
      pos += used
      out.write_bytesview(Bytes::from_array(slice[:d.last_produced()])[:])
      match status {
        Done => return (out.to_bytes(), pos)
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
  }
}

///|
test "framed streams round-trip however split, and flushes decode" {
  for input in inputs() {
    let whole = compress(input)
    assert_true(
      whole.length().to_int64() <= compress_bound(input.length().to_int64()),
    )
    assert_true(decompress(whole) == input)
    for split in [(1, 1), (7, 13), (65536, 1 << 17), (100001, 3)] {
      let (piece, room) = split
      guard input.length() <= 70000 || piece > 1 else { continue }
      assert_eq(encode_split(input, piece, room), whole)
      let (got, used) = decode_split(whole, piece, room)
      assert_true(got == input)
      assert_eq(used, whole.length())
    }
    // A flush every 1,000 bytes: the stream decodes, and so does every
    // prefix up to a flush.
    let flushed = encode_split(input, 1000, 4096, flush=_ => true)
    assert_true(decompress(flushed) == input)
    assert_true(
      flushed.length().to_int64() <=
      compress_bound(input.length().to_int64()) +
      8L * (input.length() / 1000).to_int64(),
    )
  }
}

///|
test "framed streams that break the format are refused" {
  let good = compress(b"hello hello hello hello")
  // The chunk's CRC: after the 10-byte identifier and the 4-byte header.
  let bad_crc = good.to_array()
  bad_crc[14] = bad_crc[14] ^ b'\x01'
  // No bytes at all are the empty stream, as the snap crate writes it; ours
  // is the identifier alone, as the format has every stream begin with it.
  assert_eq(decompress(b""), b"")
  assert_eq(compress(b""), b"\xff\x06\x00\x00sNaPpY")
  assert_eq(decompress(compress(b""), max_output=-1), b"")
  let cases : Array[(Bytes, String)] = [
    (b"\x00\x05\x00\x00abcde", "Corrupt"),
    (b"\xff\x06\x00\x00sNaPpX", "Corrupt"),
    (b"\xff\x05\x00\x00sNaPp", "Corrupt"),
    (b"\xff\x06\x00\x00sNaPpY\x02\x00\x00\x00", "Corrupt"),
    (b"\xff\x06\x00\x00sNaPpY\x01\x02\x00\x00ab", "Corrupt"),
    (b"\xff\x06\x00\x00sNaPpY\x01\x05\x00\x01", "Corrupt"),
    // A compressed chunk that says it decodes to 65,537 bytes.
    (
      b"\xff\x06\x00\x00sNaPpY\x00\x07\x00\x00\x00\x00\x00\x00\x81\x80\x04", "Corrupt",
    ),
    (Bytes::from_array(bad_crc), "ChecksumMismatch"),
    (good[:good.length() - 1].to_owned(), "Truncated"),
    (b"\xff\x06\x00", "Truncated"),
  ]
  for c in cases {
    let (stream, kind) = c
    assert_eq(
      error_kind(() => decompress(stream) |> ignore),
      kind,
      msg="\{stream}",
    )
  }
  let long = compress(Bytes::make(1000, b'q'))
  assert_eq(
    error_kind(() => decompress(long, max_output=999) |> ignore),
    "LimitExceeded({ resource: Output, needed: None, limit: 999 })",
  )
  assert_eq(decompress(long, max_output=1000).length(), 1000)
  // A chunk's bytes come out before its checksum's error, as provisional
  // output.
  let d = Decoder()
  let out = FixedArray::make(100, b'\x00')
  assert_eq(
    error_kind(() => {
      d.step(Bytes::from_array(bad_crc)[:], out.mut_view(), end=true) |> ignore
    }),
    "ChecksumMismatch",
  )
  assert_eq(d.last_produced(), 23)
  assert_eq(Bytes::from_array(out[:23]), b"hello hello hello hello")
  // A chunk that breaks off gives the bytes decoded before the break: "a",
  // then a copy from offset 0.
  let d = Decoder()
  let broken = b"\xff\x06\x00\x00sNaPpY\x00\x09\x00\x00\x00\x00\x00\x00\x02\x00a\x01\x00"
  assert_eq(
    error_kind(() => d.step(broken[:], out.mut_view(), end=true) |> ignore),
    "Corrupt",
  )
  assert_eq((d.last_consumed(), d.last_produced()), (23, 1))
  assert_eq(out[0], b'a')
  // A compressed chunk longer than any encoder writes, which the format
  // allows, is past what the decoder holds.
  assert_eq(
    error_kind(() => {
      decompress(b"\xff\x06\x00\x00sNaPpY\x00\xcf\x2a\x01") |> ignore
    }),
    "LimitExceeded({ resource: Memory, needed: Some(76495), limit: 76494 })",
  )
  // The checksum is not checked when asked not to.
  let d = Decoder(verify_checksums=false)
  let out = FixedArray::make(100, b'\x00')
  let _ = d.step(Bytes::from_array(bad_crc)[:], out.mut_view(), end=true)
  assert_eq(d.last_produced(), 23)
}

///|
test "skippable chunks and padding are skipped, streams follow one another" {
  let a = compress(b"first")
  let b = compress(b"second")
  let padding = b"\xfe\x03\x00\x00xyz" + b"\x80\x01\x00\x00!"
  let stream = a + padding + b
  assert_eq(decompress(stream), b"firstsecond")
  // EndOfMember stops before the second stream's identifier.
  let (got, used) = decode_split(stream, 1, 3, until=EndOfMember)
  assert_eq(got, b"first")
  assert_eq(used, a.length() + padding.length())
  // Data after the stream under EndOfInput: another stream's chunks are
  // read on; a byte that starts no chunk is a header cut short.
  assert_eq(error_kind(() => decompress(a + b"\x01") |> ignore), "Truncated")
}

///|
test "memory stays what the bounds say" {
  let e = Encoder()
  assert_eq(e.memory_usage().to_int64(), encoder_memory_bound())
  let d = Decoder()
  let stream = compress(sample(200000, 9, text=true))
  let out = FixedArray::make(1000, b'\x00')
  let mut rest = stream[:]
  for ;; {
    let status = d.step(rest, out.mut_view(), end=true)
    rest = rest[d.last_consumed():]
    assert_true(d.memory_usage().to_int64() <= decoder_memory_bound())
    if status is Done {
      break
    }
  }
  assert_eq(d.memory_usage().to_int64(), decoder_memory_bound())
}

///|
/// A stream snap wrote (snappy/scripts/gen_vectors.mbtx).
priv struct Vector {
  name : String
  format : String
  size : Int32
  sha256 : String
  stream : String
}

///|
test "snap's streams decode to their inputs, and ours are as small" {
  for v in vectors {
    let stream = @base64.decode(v.stream, ignore_whitespace=true)
    let got = if v.format == "snappy-raw" {
      decompress_raw(stream)
    } else {
      decompress(stream)
    }
    assert_eq(got.length(), v.size, msg=v.name)
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
    // In pieces too.
    if v.format == "snappy-frame" && v.size <= 70000 {
      let (pieces, _) = decode_split(stream, 7, 5)
      assert_eq(@checksum.sha256(pieces), v.sha256, msg=v.name)
    }
    // The raw format is the same encoding as snap's, byte for byte.
    if v.format == "snappy-raw" {
      assert_eq(compress_raw(got), stream, msg=v.name)
    }
  }
}

///|
test "copies with four-byte offsets, and long copies, decode" {
  // A literal "a", then a copy of 4 bytes one back with a 4-byte offset.
  assert_eq(decompress_raw(b"\x05\x00a\x0f\x01\x00\x00\x00"), b"aaaaa")
  // Copies of 65 to 67 bytes take one of 60 and one of the rest, so that
  // neither is shorter than 4.
  for len in 64..<=70 {
    let out = Writer::new(100)
    out.varint(len + 1)
    emit_literal(out, b"a", 0, 1)
    emit_copy(out, 1, len)
    assert_eq(decompress_raw(out.to_bytes()), Bytes::make(len + 1, b'a'))
  }
}

///|
test "the bounds saturate" {
  assert_eq(raw_compress_bound(0x7FFFFFFFFFFFFFFFL), 0x7FFFFFFFFFFFFFFFL)
  assert_eq(compress_bound(0x7FFFFFFFFFFFFFFFL), 0x7FFFFFFFFFFFFFFFL)
  assert_eq(raw_compress_bound(-1), 32)
}

///|
/// Decodes `input` through the `Decode` trait in slices of 7 bytes.
fn[D : @codec_bytes.Decode] decode_generic(d : D, input : Bytes) -> Bytes raise {
  d.reset()
  let out = Buffer()
  let slice = FixedArray::make(7, b'\x00')
  let mut rest = input[:]
  for ;; {
    let status = d.step(rest, slice.mut_view(), end=true)
    rest = rest[d.last_consumed():]
    out.write_bytesview(Bytes::from_array(slice[:d.last_produced()])[:])
    assert_true(d.memory_usage() >= 0)
    if status is Done {
      return out.to_bytes()
    }
  }
}

///|
/// Encodes `input` through the `Encode` trait in slices of 7 bytes.
fn[E : @codec_bytes.Encode] encode_generic(e : E, input : Bytes) -> Bytes raise {
  e.reset()
  let out = Buffer()
  let slice = FixedArray::make(7, b'\x00')
  let mut rest = input[:]
  for ;; {
    let status = e.step(rest, slice.mut_view(), action=Finish)
    rest = rest[e.last_consumed():]
    out.write_bytesview(Bytes::from_array(slice[:e.last_produced()])[:])
    assert_true(e.memory_usage() > 0)
    if status is Done {
      return out.to_bytes()
    }
  }
}

///|
test "reset, the end of a stream, and errors that stay" {
  let text = b"hello hello hello hello"
  let e = Encoder()
  let stream = encode_generic(e, text)
  assert_true(e.is_finished())
  // A step after the end takes and writes nothing.
  let slice = FixedArray::make(64, b'\x00')
  assert_true(e.step(text[:], slice.mut_view(), action=Finish) is Done)
  assert_eq((e.last_consumed(), e.last_produced()), (0, 0))
  // After reset the encoder writes the same stream again.
  assert_eq(encode_generic(e, text), stream)
  let d = Decoder()
  assert_eq(decode_generic(d, stream), text)
  assert_true(d.is_finished())
  assert_eq(decode_generic(d, stream), text)
  // Bytes passed after the end, under EndOfInput, are trailing data.
  assert_eq(
    error_kind(() => d.step(b"x"[:], slice.mut_view(), end=true) |> ignore),
    "TrailingData",
  )
  // An error stays until reset.
  let d = Decoder()
  let bad = b"\xff\x06\x00\x00sNaPpX"
  assert_eq(
    error_kind(() => d.step(bad[:], slice.mut_view(), end=true) |> ignore),
    "Corrupt",
  )
  assert_eq(
    error_kind(() => d.step(stream[:], slice.mut_view(), end=true) |> ignore),
    "Corrupt",
  )
  d.reset()
  let _ = d.step(stream[:], slice.mut_view(), end=true)
  assert_eq(Bytes::from_array(slice[:d.last_produced()]), text)
  // A skippable chunk cut short.
  assert_eq(
    error_kind(() => {
      decompress(b"\xff\x06\x00\x00sNaPpY\xfe\x05\x00\x00ab") |> ignore
    }),
    "Truncated",
  )
}
