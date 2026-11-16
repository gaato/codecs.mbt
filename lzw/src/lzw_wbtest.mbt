///|
/// The kind of error `f` raises, or "none".
fn error_kind(f : () -> Unit raise @codec.CodecError) -> String {
  f() catch {
    @codec.CodecError(kind, _) => return @debug.to_string(kind)
  }
  "none"
}

///|
/// Bytes from a seeded LCG, as src/internal/crosscheck makes them.
fn sample(n : Int32, seed : UInt64, text~ : Bool) -> Bytes {
  let words = [
    "the ", "lzw ", "code ", "table ", "of ", "clear ", "string ", "and ", "a ",
    "image ", "\n",
  ]
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
/// Every format the tests use, with the bits of a byte it codes.
fn formats() -> Array[(String, Format, Int32)] raise @codec.CodecError {
  [
    ("gif-1", Format::gif(1), 1),
    ("gif-2", Format::gif(2), 2),
    ("gif-4", Format::gif(4), 4),
    ("gif-8", Format::gif(8), 8),
    ("tiff", Format::tiff(), 8),
    ("pdf", Format::pdf(), 8),
    ("msb", Format::pdf(early_change=false), 8),
    ("z16", Format::unix_compress(), 8),
    ("z12", Format::unix_compress(max_bits=12), 8),
    ("z10", Format::unix_compress(max_bits=10), 8),
    ("znb", Format::unix_compress(block_mode=false), 8),
  ]
}

///|
/// `input` with each byte's low `bits` bits.
fn masked(input : Bytes, bits : Int32) -> Bytes {
  Bytes::makei(input.length(), i => {
    (input[i].to_int() & ((1 << bits) - 1)).to_byte()
  })
}

///|
/// Decodes `input` with `d`, in pieces of `piece` bytes into slices of
/// `room`; the output and the error kind (or "none").
fn decode_split(
  d : Decoder,
  input : Bytes,
  piece : Int32,
  room : Int32,
) -> (Bytes, String) {
  let out = Buffer()
  let slice = FixedArray::make(room, b'\x00')
  let mut pos = 0
  for ;; {
    let end = (pos + piece).min(input.length())
    let status = d.step(
      input[pos:end],
      slice.mut_view(),
      end=end == input.length(),
    ) catch {
      @codec.CodecError(kind, _) => {
        out.write_bytesview(Bytes::from_array(slice[:d.last_produced()])[:])
        return (out.to_bytes(), @debug.to_string(kind))
      }
    }
    out.write_bytesview(Bytes::from_array(slice[:d.last_produced()])[:])
    pos += d.last_consumed()
    if status is Done {
      return (out.to_bytes(), "none")
    }
  }
}

///|
/// Encodes `input` with `e`, in steps of `piece` input bytes into slices of
/// `room`.
fn encode_split(
  e : Encoder,
  input : Bytes,
  piece : Int32,
  room : Int32,
) -> Bytes raise {
  let out = Buffer()
  let slice = FixedArray::make(room, b'\x00')
  let mut pos = 0
  for ;; {
    let end = (pos + piece).min(input.length())
    let action : @codec_bytes.EncodeAction = if end == input.length() {
      Finish
    } else {
      Continue
    }
    let status = e.step(input[pos:end], slice.mut_view(), action~)
    out.write_bytesview(Bytes::from_array(slice[:e.last_produced()])[:])
    pos += e.last_consumed()
    if status is Done {
      return out.to_bytes()
    }
  }
}

///|
test "formats outside their ranges are refused" {
  for size in [0, 9, -1] {
    assert_eq(error_kind(() => Format::gif(size) |> ignore), "Unsupported")
  }
  for bits in [8, 9, 17] {
    assert_eq(
      error_kind(() => Format::unix_compress(max_bits=bits) |> ignore),
      "Unsupported",
    )
  }
  let gif = Format::gif(4)
  assert_eq(gif.literal_bits, 4)
  assert_eq(Format::pdf(), Format::tiff())
  assert_true(Format::pdf(early_change=false) != Format::tiff())
}

///|
test "streams round-trip in every format, however split, within the bounds" {
  let inputs = [
    b"",
    b"a",
    b"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    sample(5000, 1, text=true),
    sample(3000, 2, text=false),
    // Long enough to fill every table, so that GIF's and TIFF's clear and
    // .Z's ratio check clears.
    sample(150000, 3, text=true) +
    sample(60000, 4, text=false) +
    sample(80000, 5, text=true),
  ]
  for f in formats() {
    let (name, format, bits) = f
    for raw in inputs {
      let input = masked(raw, bits)
      let whole = compress(input, format)
      assert_true(
        whole.length().to_int64() <=
        compress_bound(input.length().to_int64(), format),
        msg="\{name} bound",
      )
      assert_eq(decompress(whole, format), input, msg="\{name}")
      let pieces = encode_split(Encoder(format), input, 777, 5)
      assert_eq(pieces, whole, msg="\{name} pieces")
      let d = Decoder(format)
      let (out, kind) = decode_split(d, whole, 333, 17)
      assert_eq(kind, "none", msg="\{name}")
      assert_eq(out, input, msg="\{name}")
      assert_true(d.is_finished())
      assert_true(
        d.memory_usage().to_int64() <= decoder_memory_bound(format),
        msg="\{name} memory",
      )
    }
  }
}

///|
/// Writes codes as an encoder of `format` would, without its choices: every
/// code given, at the width the decoder reads it at, with .Z's padding.
fn hand_written(format : Format, codes : Array[Int32]) -> Bytes {
  let out = Buffer()
  let mut acc = 0U
  let mut nbits = 0
  let mut bits = format.initial_bits()
  let mut since = 0
  let put = (code : Int32, n : Int32) => {
    let c = code.reinterpret_as_uint()
    if format.msb_first {
      acc = (acc << n) | c
      nbits += n
      while nbits >= 8 {
        out.write_byte((acc >> (nbits - 8)).to_byte())
        nbits -= 8
        acc = acc & ((1U << nbits) - 1)
      }
    } else {
      acc = acc | (c << nbits)
      nbits += n
      while nbits >= 8 {
        out.write_byte((acc & 0xFF).to_byte())
        acc = acc >> 8
        nbits -= 8
      }
    }
  }
  for code in codes {
    if code == format.clear_code() && format.block_mode {
      put(code, bits)
      bits = format.initial_bits()
      since = 0
      continue
    }
    bits = format.width(bits, format.first_code() + since)
    put(code, bits)
    since += 1
  }
  if nbits > 0 {
    put(0, 8 - nbits)
  }
  out.to_bytes()
}

///|
test "a full GIF table without a clear keeps its codes, as GIF89a allows" {
  // Literals only, past the 4,090 codes that fill a table of minimum code
  // size 2, then the end code: the decoder stops defining codes and goes on
  // reading 12-bit ones.
  let format = Format::gif(2)
  let literals = Array::makei(5000, i => (i * 7 + i / 3) % 4)
  let stream = hand_written(
    format,
    [format.clear_code(), ..literals, format.end_code()],
  )
  let expected = Bytes::from_array(literals.map(c => c.to_byte()))
  assert_eq(decompress(stream, format), expected)
}

///|
test "streams that break the format are refused" {
  let gif = Format::gif(8)
  let z = Format::unix_compress()
  let good = compress(b"hello hello hello", gif)
  let cases : Array[(Bytes, Format, String)] = [
    // A first code that is no literal, and a code past the table.
    (hand_written(gif, [258, gif.end_code()]), gif, "Corrupt"),
    (hand_written(gif, [104, 300, gif.end_code()]), gif, "Corrupt"),
    // No end code, nothing at all, and bytes after the end.
    (good[:good.length() - 2].to_owned(), gif, "Truncated"),
    (b"", gif, "Truncated"),
    (good + b"\x00", gif, "TrailingData"),
    // .Z: the magic number, the widths, a header cut short.
    (b"\x1f\x9e\x90", z, "Corrupt"),
    (b"\x1f\x9d\x91", z, "Unsupported"),
    (b"\x1f\x9d\x89", z, "Unsupported"),
    (b"\x1f\x9d\x88", z, "Corrupt"),
    (b"\x1f\x9d", z, "Truncated"),
    // .Z must begin with a literal: a clear, or a code of the table, is
    // refused, as compress and gzip refuse them.
    (b"\x1f\x9d\x90\x00\x01", z, "Corrupt"),
    (b"\x1f\x9d\x90\x01\x01", z, "Corrupt"),
  ]
  for c in cases {
    let (stream, format, kind) = c
    assert_eq(
      error_kind(() => decompress(stream, format) |> ignore),
      kind,
      msg="\{stream[:stream.length().min(8)]}",
    )
  }
  // A stream without its end code, taken as ending with the input.
  let cut = good[:good.length() - 2].to_owned()
  let (out, kind) = decode_split(
    Decoder(gif, allow_missing_end=true),
    cut,
    3,
    5,
  )
  assert_eq(kind, "none")
  assert_true(out.length() > 0 && b"hello hello hello"[:].has_prefix(out[:]))
  // A .Z wider than the decoder allows.
  let wide = compress(b"some text some text", z)
  assert_eq(
    error_kind(() => {
      decompress(wide, Format::unix_compress(max_bits=12)) |> ignore
    }),
    "LimitExceeded({ resource: Memory, needed: Some(393216), limit: 24576 })",
  )
  // .Z ends with the input: any whole prefix of codes decodes.
  assert_eq(decompress(wide[:3], z), b"")
}

///|
test "EndOfMember stops after the end code; .Z and Flush are refused" {
  let gif = Format::gif(8)
  let a = compress(b"first stream", gif)
  let b = compress(b"second", gif)
  let d = Decoder(gif, until=EndOfMember)
  let slice = FixedArray::make(100, b'\x00')
  assert_true(d.step((a + b)[:], slice.mut_view(), end=true) is Done)
  assert_eq(d.last_consumed(), a.length())
  assert_eq(Bytes::from_array(slice[:d.last_produced()]), b"first stream")
  // Under EndOfInput, the end code ends the stream but not the input:
  // until `end`, the decoder waits, and bytes that come are trailing data.
  let d = Decoder(gif)
  assert_true(d.step(a[:], slice.mut_view(), end=false) is NeedMoreInput)
  assert_eq(
    error_kind(() => d.step(b"x"[:], slice.mut_view(), end=true) |> ignore),
    "TrailingData",
  )
  assert_eq(d.last_consumed(), 0)
  let d = Decoder(gif)
  assert_true(d.step(a[:], slice.mut_view(), end=false) is NeedMoreInput)
  assert_true(d.step(b""[:], slice.mut_view(), end=true) is Done)
  let dz = Decoder(Format::unix_compress(), until=EndOfMember)
  assert_eq(
    error_kind(() => {
      dz.step(b"\x1f\x9d\x90"[:], slice.mut_view(), end=true) |> ignore
    }),
    "Unsupported",
  )
  let e = Encoder(gif)
  assert_eq(
    error_kind(() => e.step(b"abc"[:], slice.mut_view(), action=Flush) |> ignore),
    "Unsupported",
  )
  assert_eq(
    error_kind(() => {
      e.step(b"abc"[:], slice.mut_view(), action=Finish) |> ignore
    }),
    "Unsupported",
  )
  // A byte a minimum code size of 2 cannot code.
  let e = Encoder(Format::gif(2))
  assert_eq(
    error_kind(() => {
      e.step(b"\x00\x04"[:], slice.mut_view(), action=Finish) |> ignore
    }),
    "Unsupported",
  )
  assert_eq(e.last_consumed(), 1)
  // The output of the bytes before such a byte comes first, however the
  // input is split.
  let bytes = b"\x00\x01\x02\x04"
  let whole = Encoder(Format::gif(2))
  assert_eq(
    error_kind(() => {
      whole.step(bytes[:], slice.mut_view(), action=Finish) |> ignore
    }),
    "Unsupported",
  )
  let together = Bytes::from_array(slice[:whole.last_produced()])
  let apart = Encoder(Format::gif(2))
  let out = Buffer()
  for i in 0..<4 {
    let kind = error_kind(() => {
      apart.step(bytes[i:i + 1], slice.mut_view(), action=Continue) |> ignore
    })
    out.write_bytesview(Bytes::from_array(slice[:apart.last_produced()])[:])
    if kind != "none" {
      assert_eq(kind, "Unsupported")
      break
    }
  }
  assert_eq(together, out.to_bytes())
  assert_true(together.length() > 0)
}

///|
/// Decodes through the `Decode` trait in slices of 7 bytes.
fn[D : @codec_bytes.Decode] decode_generic(d : D, input : Bytes) -> Bytes raise {
  d.reset()
  let out = Buffer()
  let slice = FixedArray::make(7, b'\x00')
  let mut rest = input[:]
  for ;; {
    let status = d.step(rest, slice.mut_view(), end=true)
    rest = rest[d.last_consumed():]
    out.write_bytesview(Bytes::from_array(slice[:d.last_produced()])[:])
    assert_true(d.memory_usage() > 0)
    if status is Done {
      return out.to_bytes()
    }
  }
}

///|
/// Encodes through the `Encode` trait in slices of 7 bytes.
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
test "reset, the end of a stream, errors that stay, and memory" {
  let text = sample(3000, 6, text=true)
  for f in formats() {
    let (name, format, bits) = f
    let input = masked(text, bits)
    let e = Encoder(format)
    let stream = encode_generic(e, input)
    assert_true(e.is_finished())
    assert_eq(e.memory_usage().to_int64(), encoder_memory_bound(format))
    let slice = FixedArray::make(64, b'\x00')
    assert_true(e.step(input[:], slice.mut_view(), action=Finish) is Done)
    assert_eq(encode_generic(e, input), stream, msg=name)
    let d = Decoder(format)
    assert_eq(decode_generic(d, stream), input, msg=name)
    assert_eq(decode_generic(d, stream), input, msg=name)
    assert_eq(d.stream_format().max_bits, format.max_bits)
  }
  let d = Decoder(Format::gif(8))
  let slice = FixedArray::make(64, b'\x00')
  let bad = hand_written(Format::gif(8), [300])
  assert_eq(
    error_kind(() => d.step(bad[:], slice.mut_view(), end=true) |> ignore),
    "Corrupt",
  )
  assert_eq(
    error_kind(() => d.step(bad[:], slice.mut_view(), end=true) |> ignore),
    "Corrupt",
  )
  assert_eq((d.last_consumed(), d.last_produced()), (0, 0))
}

///|
test "the bounds saturate" {
  let f = Format::tiff()
  assert_eq(compress_bound(0x7FFFFFFFFFFFFFFFL, f), 0x7FFFFFFFFFFFFFFFL)
  assert_eq(compress_bound(-1, f), 3L + (3L * 12L + 7L) / 8L)
  assert_eq(decoder_memory_bound(f), 28673)
  assert_eq(decoder_memory_bound(Format::unix_compress()), 458753)
}

///|
/// A stream a reference wrote (lzw/scripts/gen_vectors.mbtx).
priv struct Vector {
  name : String
  set : String
  size : Int32
  sha256 : String
  stream : String
}

///|
fn vector_format(set : String) -> Format raise @codec.CodecError {
  match set {
    "gif-2" => Format::gif(2)
    "gif-4" => Format::gif(4)
    "gif-8" => Format::gif(8)
    "tiff" => Format::tiff()
    "msb" => Format::pdf(early_change=false)
    "z12" => Format::unix_compress(max_bits=12)
    "z10" => Format::unix_compress(max_bits=10)
    _ => Format::unix_compress()
  }
}

///|
test "weezl's and compress's streams decode to their inputs, and ours are theirs" {
  for v in vectors {
    let format = vector_format(v.set)
    let stream = @base64.decode(v.stream, ignore_whitespace=true)
    let got = decompress(stream, format)
    assert_eq(got.length(), v.size, msg="\{v.name} \{v.set}")
    assert_eq(@checksum.sha256(got), v.sha256, msg="\{v.name} \{v.set}")
    if v.size <= 70000 {
      let (pieces, kind) = decode_split(Decoder(format), stream, 7, 5)
      assert_eq(kind, "none", msg="\{v.name} \{v.set}")
      assert_eq(@checksum.sha256(pieces), v.sha256, msg="\{v.name} \{v.set}")
    }
    // Our .Z is compress's, to the byte; GIF and TIFF are weezl's until
    // the table fills, when we clear it where giflib and libtiff do.
    if v.set.has_prefix("z") || v.size <= 5000 {
      assert_eq(compress(got, format), stream, msg="\{v.name} \{v.set}")
    }
  }
}

///|
test ".Z padding split anywhere or cut short, max_output, and Continue" {
  // A change of width comes after a multiple of eight codes, so only a
  // clear pads. Text, then noise, then text, at 10 bits: the table fills,
  // and the ratio check clears it when the noise comes.
  let z = Format::unix_compress(max_bits=10)
  let input = sample(30000, 7, text=true) +
    sample(20000, 8, text=false) +
    sample(30000, 9, text=true)
  let stream = compress(input, z)
  // Byte by byte: the padding waits for its bytes.
  let d = Decoder(z)
  let slice = FixedArray::make(3, b'\x00')
  let out = Buffer()
  let padded = []
  let mut i = 0
  for ;; {
    let last = i + 1 >= stream.length()
    let status = d.step(stream[i:i + 1], slice.mut_view(), end=last)
    out.write_bytesview(Bytes::from_array(slice[:d.last_produced()])[:])
    i += d.last_consumed()
    if d.skip > 0 {
      padded.push(i)
    }
    if status is Done {
      break
    }
  }
  assert_eq(out.to_bytes(), input)
  assert_true(padded.length() > 0)
  // Cut inside the padding: what came before it, as compress reads it.
  for cut in padded {
    let (got, kind) = decode_split(Decoder(z), stream[:cut].to_owned(), 7, 100)
    assert_eq(kind, "none")
    assert_true(input[:].has_prefix(got[:]))
  }
  // max_output of a whole stream.
  assert_eq(
    error_kind(() => decompress(stream, z, max_output=4999) |> ignore),
    "LimitExceeded({ resource: Output, needed: None, limit: 4999 })",
  )
  assert_eq(decompress(stream, z, max_output=input.length()), input)
  // Continue takes the input and asks for more.
  let e = Encoder(Format::tiff())
  let slice = FixedArray::make(64, b'\x00')
  assert_true(
    e.step(b"abc"[:], slice.mut_view(), action=Continue) is NeedMoreInput,
  )
  assert_eq(e.last_consumed(), 3)
}
