///|
/// The kind of error `f` raises, or "none".
fn error_kind(f : () -> Unit raise @codec.CodecError) -> String {
  f() catch {
    @codec.CodecError(kind, _) => return @debug.to_string(kind)
  }
  "none"
}

///|
/// Bytes from a seeded LCG: text from a small vocabulary, or noise, as
/// src/internal/crosscheck makes them.
fn sample(n : Int32, seed : UInt64, text~ : Bool) -> Bytes {
  let words = [
    "the ", "lz4 ", "frame ", "block ", "of ", "match ", "literal ", "and ", "a ",
    "stream ", "\n",
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
    assert_true(d.memory_usage().to_int64() <= decoder_memory_bound()) catch {
      _ => abort("memory")
    }
    pos += d.last_consumed()
    if status is Done {
      return (out.to_bytes(), "none")
    }
  }
}

///|
/// Encodes `input` with `e`, in steps of `piece` input bytes into slices of
/// `room`, flushing where `flush` says.
fn encode_split(
  e : Encoder,
  input : Bytes,
  piece : Int32,
  room : Int32,
  flush~ : (Int32) -> Bool = _ => false,
) -> Bytes raise {
  let out = Buffer()
  let slice = FixedArray::make(room, b'\x00')
  let mut pos = 0
  for ;; {
    let end = (pos + piece).min(input.length())
    let action : @codec_bytes.EncodeAction = if end == input.length() {
      Finish
    } else if flush(pos) {
      Flush
    } else {
      Continue
    }
    let status = e.step(input[pos:end], slice.mut_view(), action~)
    out.write_bytesview(Bytes::from_array(slice[:e.last_produced()])[:])
    assert_eq(e.memory_usage(), e.memory_usage())
    assert_true(
      e.memory_usage().to_int64() <= encoder_memory_bound(block_size=Max4MiB),
    )
    pos += e.last_consumed()
    if status is Done {
      return out.to_bytes()
    }
  }
}

///|
test "XXH32 gives the specification's values" {
  assert_eq(xxh32(b""[:]), 0x02CC5D05)
  assert_eq(xxh32(b"a"[:]), 0x550D7456)
  assert_eq(xxh32(b"abc"[:]), 0x32D153FF)
  assert_eq(xxh32(b"Nobody inspects the spammish repetition"[:]), 0xE2293B2F)
  // Fed in pieces of every size, from arrays and from views alike.
  let data = sample(1000, 3, text=false)
  let whole = xxh32(data[:])
  for piece in [1, 3, 15, 16, 17, 100] {
    let a = Xxh32::new()
    let v = Xxh32::new()
    let arr = data.to_fixedarray()
    let mut i = 0
    while i < data.length() {
      let n = piece.min(data.length() - i)
      a.update(arr, i, n)
      v.update_view(data[i:i + n])
      i += n
    }
    assert_eq(a.digest(), whole)
    assert_eq(v.digest(), whole)
  }
}

///|
test "blocks that break the format are refused" {
  // "a", a match of 8 one back, then the last literals: none.
  assert_eq(decompress_block(b"\x14a\x01\x00\x00", max_output=9), b"aaaaaaaaa")
  assert_eq(decompress_block(b"\x10a", max_output=1), b"a")
  let cases : Array[(Bytes, String)] = [
    (b"", "Corrupt"),
    // Literals past the block, and lengths and offsets cut short.
    (b"\x10", "Corrupt"),
    (b"\xF0", "Corrupt"),
    (b"\x14a\x01", "Corrupt"),
    (b"\x1Fa\x01\x00", "Corrupt"),
    // A block that ends after a match, not with literals.
    (b"\x14a\x01\x00", "Corrupt"),
    // An offset of 0, and one before the start.
    (b"\x14a\x00\x00\x00", "Corrupt"),
    (b"\x14a\x02\x00\x00", "Corrupt"),
  ]
  for c in cases {
    let (block, kind) = c
    assert_eq(
      error_kind(() => decompress_block(block, max_output=100) |> ignore),
      kind,
      msg="\{block}",
    )
  }
  assert_eq(
    error_kind(() => {
      decompress_block(b"\x14a\x01\x00\x00", max_output=8) |> ignore
    }),
    "LimitExceeded({ resource: Output, needed: None, limit: 8 })",
  )
  // A match that reaches into the dictionary, and without it.
  assert_eq(
    decompress_block(b"\x00\x02\x00\x00", max_output=4, dictionary=b"xy"),
    b"xyxy",
  )
  assert_eq(
    error_kind(() => {
      decompress_block(b"\x00\x02\x00\x00", max_output=4) |> ignore
    }),
    "Corrupt",
  )
  // A length of many 255s stops at the limit, and does not overflow.
  let long = Bytes::makei(100000, i => if i == 0 { b'\xF0' } else { b'\xFF' })
  assert_eq(
    error_kind(() => decompress_block(long, max_output=0x7FFFFFFF) |> ignore),
    "Corrupt",
  )
}

///|
test "blocks round-trip, within the bound, with and without a dictionary" {
  let dict = sample(30000, 5, text=true)
  for n in [0, 1, 12, 13, 14, 100, 5000, 65546, 65547, 100000] {
    for text in [true, false] {
      let input = sample(n, n.to_uint64(), text~)
      for acceleration in [1, 2, 9, 1000] {
        let block = compress_block(input, acceleration~)
        assert_true(
          block.length().to_int64() <= block_compress_bound(n.to_int64()),
        )
        assert_eq(decompress_block(block, max_output=n), input)
        let with_dict = compress_block(input, acceleration~, dictionary=dict)
        assert_true(
          with_dict.length().to_int64() <= block_compress_bound(n.to_int64()),
        )
        assert_eq(
          decompress_block(with_dict, max_output=n, dictionary=dict),
          input,
        )
      }
    }
  }
  // A dictionary helps a small input that shares its words.
  let small = sample(2000, 6, text=true)
  assert_true(
    compress_block(small, dictionary=dict).length() <
    compress_block(small).length(),
  )
}

///|
/// `frame` with its header checksum made right again, after a change to its
/// descriptor of `len` bytes from byte 4.
fn rehash(frame : FixedArray[Byte], len : Int32) -> Bytes {
  let hc = xxh32(frame.unsafe_reinterpret_as_bytes()[4:4 + len - 1]) >> 8
  frame[4 + len - 1] = (hc & 0xFF).reinterpret_as_int().to_byte()
  Bytes::from_array(frame[:])
}

///|
test "frames that break the format are refused" {
  let text = sample(5000, 21, text=true)
  let good = compress(text, linked=false, block_checksum=true)
  assert_eq(decompress(good), text)
  let changed = (at : Int32, f : (Int32) -> Int32, rehashed : Bool) => {
    let a = good.to_fixedarray()
    a[at] = f(a[at].to_int()).to_byte()
    if rehashed {
      rehash(a, 3)
    } else {
      Bytes::from_array(a[:])
    }
  }
  let cases : Array[(Bytes, String)] = [
    (b"\x05\x22\x4D\x18", "Corrupt"),
    // Version 2, a reserved flag, a reserved BD bit, a block size code of 3.
    (changed(4, b => b ^ 0xC0, true), "Unsupported"),
    (changed(4, b => b | 0x02, true), "Unsupported"),
    (changed(5, b => b | 0x01, true), "Unsupported"),
    (changed(5, _ => 0x30, true), "Unsupported"),
    // The header checksum, a block's checksum, the content checksum.
    (changed(6, b => b ^ 1, false), "ChecksumMismatch"),
    (changed(good.length() - 9, b => b ^ 1, false), "ChecksumMismatch"),
    (changed(good.length() - 1, b => b ^ 1, false), "ChecksumMismatch"),
    // A block over the frame's maximum: 64 KiB + 1.
    (
      b"\x04\x22\x4D\x18\x40\x40\xC0\x01\x00\x01\x00" + Bytes::make(70000, b'x'),
      "Corrupt",
    ),
    // Cut short, nothing at all, and data after the frame.
    (good[:good.length() - 1].to_owned(), "Truncated"),
    (good[:5].to_owned(), "Truncated"),
    (b"", "Truncated"),
    (good + b"XYZW", "TrailingData"),
    (good + b"\x04\x22", "Truncated"),
    (good + b"\x5F\x2A", "Truncated"),
    // A byte that begins no magic number is trailing data at once.
    (good + b"\xFF", "TrailingData"),
    (good + b"\x04\x23", "TrailingData"),
  ]
  // Fix the BD case's header checksum and the long block's.
  for c in cases {
    let (stream, kind) = c
    let got = error_kind(() => decompress(stream) |> ignore)
    if stream.length() > 60000 {
      // The long block's header checksum is computed here.
      let a = stream.to_fixedarray()
      let fixed = rehash(a, 3)
      assert_eq(error_kind(() => decompress(fixed) |> ignore), kind)
      continue
    }
    assert_eq(got, kind, msg="\{stream[:stream.length().min(12)]}")
  }
  // Trailing data stops at the end of the stream, in this step's input or,
  // when the bytes came before it, at once.
  let d = Decoder()
  let slice = FixedArray::make(100000, b'\x00')
  let tail = good + b"\x04\xFF"
  assert_eq(
    error_kind(() => d.step(tail[:], slice.mut_view(), end=false) |> ignore),
    "TrailingData",
  )
  assert_eq(d.last_consumed(), good.length())
  let d = Decoder()
  let _ = d.step((good + b"\x04")[:], slice.mut_view(), end=false)
  assert_eq(
    error_kind(() => d.step(b"\xFF"[:], slice.mut_view(), end=true) |> ignore),
    "TrailingData",
  )
  assert_eq(d.last_consumed(), 0)
  // Bytes come out before the checksum that fails them.
  let bad = changed(good.length() - 9, b => b ^ 1, false)
  let (out, kind) = decode_split(Decoder(), bad, bad.length(), 100000)
  assert_eq(kind, "ChecksumMismatch")
  assert_eq(out, text)
  // A block that breaks off gives what it decoded first.
  let frame = compress(
    b"abcdefghabcdefghabcdefgh",
    linked=false,
    checksum=false,
  )
  let a = frame.to_fixedarray()
  // The block: size, token, 8 literals, an offset of 8; make the offset 9.
  a[4 + 3 + 4 + 1 + 8] = b'\x09'
  let (out, kind) = decode_split(Decoder(), Bytes::from_array(a[:]), 1000, 1000)
  assert_eq(kind, "Corrupt")
  assert_eq(out, b"abcdefgh")
}

///|
test "content sizes and dictionaries are checked" {
  let text = sample(3000, 22, text=true)
  // A content size that the frame does not hold, either way.
  for delta in [-1, 1] {
    let e = Encoder(content_size=text.length().to_int64())
    let a = encode_split(e, text, 3000, 100000).to_fixedarray()
    // Content size in bytes 6 to 13.
    a[6] = (a[6].to_int() + delta).to_byte()
    let bad = rehash(a, 11)
    assert_eq(error_kind(() => decompress(bad) |> ignore), "ChecksumMismatch")
  }
  // The encoder holds the input to its content size.
  let e = Encoder(content_size=10)
  let slice = FixedArray::make(1000, b'\x00')
  assert_eq(
    error_kind(() => {
      e.step(b"0123456789A"[:], slice.mut_view(), action=Finish) |> ignore
    }),
    "ChecksumMismatch",
  )
  assert_eq(e.last_consumed(), 10)
  // The error stays.
  assert_eq(
    error_kind(() => e.step(b""[:], slice.mut_view(), action=Finish) |> ignore),
    "ChecksumMismatch",
  )
  assert_eq((e.last_consumed(), e.last_produced()), (0, 0))
  let e = Encoder(content_size=10)
  assert_eq(
    error_kind(() => {
      e.step(b"012345678"[:], slice.mut_view(), action=Finish) |> ignore
    }),
    "ChecksumMismatch",
  )
  let e = Encoder(content_size=10)
  let ok = encode_split(e, b"0123456789", 3, 7)
  assert_eq(decompress(ok), b"0123456789")
  // A frame that names its dictionary.
  let dict = sample(80000, 23, text=true)
  for linked in [true, false] {
    let frame = compress(text, linked~, dictionary=dict, dictionary_id=7)
    assert_eq(
      error_kind(() => decompress(frame) |> ignore),
      "DictionaryRequired(Some(7))",
    )
    assert_eq(decompress(frame, dictionary=dict), text)
    // Only the dictionary's last 64 KiB count.
    assert_eq(decompress(frame, dictionary=dict[dict.length() - 65535:]), text)
    let d = Decoder(dictionary=dict)
    let _ = decode_split(d, frame, 100, 100)
    assert_eq(d.frame_info().unwrap().dictionary_id, Some(7U))
    assert_eq(d.frame_info().unwrap().linked, linked)
  }
}

///|
test "frames, skippable frames and legacy frames follow one another" {
  let a = sample(1000, 31, text=true)
  let b = sample(2000, 32, text=true)
  let fa = compress(a)
  let fb = compress(b, linked=false)
  let skip = skippable_frame(3, b"user data")
  assert_eq(skip[0:4], b"\x53\x2A\x4D\x18"[:])
  // A legacy frame, as the vectors' reference writes them: the magic
  // number, then a block of all of `b`.
  let block = compress_block(b)
  let size = block.length()
  let legacy = b"\x02\x21\x4C\x18" +
    Bytes::from_array([
      size.to_byte(),
      (size >> 8).to_byte(),
      (size >> 16).to_byte(),
      (size >> 24).to_byte(),
    ]) +
    block
  let stream = fa + skip + legacy + fb + legacy
  assert_eq(decompress(stream), a + b + b + b)
  // Split anyhow, the same.
  for piece in [1, 7, 100] {
    let (out, kind) = decode_split(Decoder(), stream, piece, 13)
    assert_eq(kind, "none")
    assert_eq(out, a + b + b + b)
  }
  // A legacy frame ends with the input; garbage after it is trailing data.
  assert_eq(decompress(legacy + legacy), b + b)
  assert_eq(
    error_kind(() => decompress(legacy + b"\xFF\xFF\xFF\xFF") |> ignore),
    "TrailingData",
  )
  assert_eq(
    error_kind(() => decompress(legacy + b"\x01\x00") |> ignore),
    "Truncated",
  )
  // Bytes that can begin neither a block's size nor a magic number.
  assert_eq(
    error_kind(() => decompress(legacy + b"\x00\x00\x81") |> ignore),
    "TrailingData",
  )
  assert_eq(
    error_kind(() => decompress(legacy + b"\x00\x00\x00\x00") |> ignore),
    "Corrupt",
  )
  // EndOfMember stops before the next frame, a skippable frame being one.
  let slice = FixedArray::make(100000, b'\x00')
  let d = Decoder(until=EndOfMember)
  let status = d.step(stream[:], slice.mut_view(), end=false)
  assert_true(status is Done)
  assert_eq(d.last_consumed(), fa.length())
  assert_eq(Bytes::from_array(slice[:d.last_produced()]), a)
  d.reset()
  let rest = stream[fa.length():]
  assert_true(d.step(rest, slice.mut_view(), end=false) is Done)
  assert_eq(d.last_consumed(), skip.length())
  assert_eq(d.last_produced(), 0)
  d.reset()
  assert_eq(
    error_kind(() => d.step(legacy[:], slice.mut_view(), end=true) |> ignore),
    "Unsupported",
  )
  // What the headers say.
  let d = Decoder()
  let _ = decode_split(d, legacy, 1000, 1000)
  assert_eq(d.frame_info().unwrap().legacy, true)
  assert_eq(d.frame_info().unwrap().block_size, None)
  let d = Decoder()
  let x = compress(a, block_size=Max1MiB, block_checksum=true, checksum=false)
  let _ = decode_split(d, x, 1000, 1000)
  let info = d.frame_info().unwrap()
  assert_eq(info.block_size, Some(Max1MiB))
  assert_eq(info.block_checksum, true)
  assert_eq(info.content_checksum, false)
  assert_eq(info.content_size, None)
  assert_eq(Max4MiB.bytes(), 4194304)
}

///|
test "frames round-trip however split and flushed, within the bounds" {
  let dict = sample(30000, 41, text=true)
  let inputs = [
    b"",
    b"x",
    sample(5000, 42, text=true),
    sample(3000, 43, text=false),
    sample(200000, 44, text=true),
  ]
  let options : Array[(Int32) -> Encoder] = [
    _ => Encoder(),
    _ => Encoder(linked=false),
    _ => Encoder(block_size=Max256KiB, block_checksum=true, acceleration=4),
    n => Encoder(content_size=n.to_int64(), checksum=false),
    _ => Encoder(dictionary=dict, linked=false),
    _ => Encoder(dictionary=dict),
  ]
  for input in inputs {
    for make in options {
      let whole = encode_split(
        make(input.length()),
        input,
        input.length() + 1,
        1 << 20,
      )
      assert_true(
        whole.length().to_int64() <=
        compress_bound(input.length().to_int64(), block_size=Max256KiB).min(
          compress_bound(input.length().to_int64()),
        ) +
        4,
      )
      // In pieces, into small slices, the same bytes.
      let pieces = encode_split(make(input.length()), input, 777, 5)
      assert_eq(pieces, whole)
      // Flushed every 1,000 bytes: decodes to the input, within the bound.
      let flushed = encode_split(make(input.length()), input, 1000, 999, flush=_ => {
        true
      })
      let flushes = input.length().to_int64() / 1000L
      assert_true(
        flushed.length().to_int64() <=
        compress_bound(input.length().to_int64()) + 8L * flushes,
      )
      for stream in [whole, flushed] {
        let d = Decoder(dictionary=dict)
        let (out, kind) = decode_split(d, stream, 333, 17)
        assert_eq(kind, "none")
        assert_eq(out, input)
        assert_true(d.is_finished())
      }
    }
  }
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
    assert_true(d.memory_usage() >= 0)
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
test "reset, the end of a stream, and errors that stay" {
  let text = sample(3000, 51, text=true)
  let e = Encoder()
  let stream = encode_generic(e, text)
  assert_true(e.is_finished())
  let slice = FixedArray::make(64, b'\x00')
  assert_true(e.step(text[:], slice.mut_view(), action=Finish) is Done)
  assert_eq((e.last_consumed(), e.last_produced()), (0, 0))
  assert_eq(encode_generic(e, text), stream)
  let d = Decoder()
  assert_eq(decode_generic(d, stream), text)
  assert_true(d.is_finished())
  assert_eq(decode_generic(d, stream), text)
  assert_eq(
    error_kind(() => d.step(b"x"[:], slice.mut_view(), end=true) |> ignore),
    "TrailingData",
  )
  let d = Decoder()
  assert_eq(
    error_kind(() => d.step(b"XXXX"[:], slice.mut_view(), end=true) |> ignore),
    "Corrupt",
  )
  assert_eq(
    error_kind(() => d.step(stream[:], slice.mut_view(), end=true) |> ignore),
    "Corrupt",
  )
  assert_eq((d.last_consumed(), d.last_produced()), (0, 0))
  d.reset()
  assert_eq(decode_generic(d, stream), text)
}

///|
test "memory stays within the bounds" {
  let input = sample(600000, 61, text=true)
  for bs in [Max64KiB, Max256KiB, Max1MiB, Max4MiB] {
    let e = Encoder(block_size=bs)
    assert_true(
      e.memory_usage().to_int64() <= encoder_memory_bound(block_size=bs),
    )
    let stream = encode_split(e, input, 100000, 4096)
    let d = Decoder()
    let (out, _) = decode_split(d, stream, 4096, 1000)
    assert_eq(out, input)
    // The window has grown to its full size.
    assert_eq(d.memory_usage().to_int64(), decoder_memory_bound())
  }
  let e = Encoder(block_size=Max4MiB, dictionary=b"dictionary")
  assert_eq(
    e.memory_usage().to_int64(),
    encoder_memory_bound(block_size=Max4MiB),
  )
}

///|
test "the bounds saturate" {
  assert_eq(block_compress_bound(0x7FFFFFFFFFFFFFFFL), 0x7FFFFFFFFFFFFFFFL)
  assert_eq(compress_bound(0x7FFFFFFFFFFFFFFFL), 0x7FFFFFFFFFFFFFFFL)
  assert_eq(block_compress_bound(-1), 16)
  assert_eq(compress_bound(-1), 27)
}

///|
/// A stream lz4 wrote (lz4/scripts/gen_vectors.mbtx).
priv struct Vector {
  name : String
  set : String
  size : Int32
  sha256 : String
  stream : String
}

///|
/// What gaato/lz4 writes for `input` in the sets whose options are lz4's,
/// None for the others.
fn ours(set : String, input : Bytes) -> Bytes? {
  match set {
    "b4i" => Some(compress(input, linked=false))
    "b4d" => Some(compress(input, linked=true))
    "b7i" => Some(compress(input, block_size=Max4MiB, linked=false))
    "b5ix" => {
      let e = Encoder(
        block_size=Max256KiB,
        linked=false,
        block_checksum=true,
        content_size=input.length().to_int64(),
      )
      Some(encode_split(e, input, input.length() + 1, 1 << 20)) catch {
        _ => None
      }
    }
    "fast9" =>
      Some(compress(input, linked=false, checksum=false, acceleration=9))
    "block" => Some(compress_block(input))
    _ => None
  }
}

///|
test "lz4's streams decode to their inputs, and ours are lz4's" {
  let dict = sample(20000, 99, text=true)
  assert_eq(@checksum.sha256(dict), dictionary_sha256)
  for v in vectors {
    let stream = @base64.decode(v.stream, ignore_whitespace=true)
    let with_dict = v.set.has_suffix("_dict")
    let got = if v.set.has_prefix("block") {
      decompress_block(
        stream,
        max_output=v.size,
        dictionary?=if with_dict { Some(dict[:]) } else { None },
      )
    } else if with_dict {
      decompress(stream, dictionary=dict)
    } else {
      decompress(stream)
    }
    assert_eq(got.length(), v.size, msg="\{v.name} \{v.set}")
    assert_eq(@checksum.sha256(got), v.sha256, msg="\{v.name} \{v.set}")
    // In pieces too.
    if !v.set.has_prefix("block") && v.size <= 70000 {
      let d = if with_dict { Decoder(dictionary=dict) } else { Decoder() }
      let (pieces, kind) = decode_split(d, stream, 7, 5)
      assert_eq(kind, "none", msg="\{v.name} \{v.set}")
      assert_eq(@checksum.sha256(pieces), v.sha256, msg="\{v.name} \{v.set}")
    }
    if ours(v.set, got) is Some(mine) {
      assert_eq(mine, stream, msg="\{v.name} \{v.set}")
    }
  }
}

///|
test "blocks lz4 gives up on are stored, as lz4 stores them" {
  // Literals, then a match near the end: lz4's room checks give up before
  // the literals or the match fit one byte less than the block, and the
  // block is stored.
  let r = sample(31000, 71, text=false)
  // Long literals make lz4 step over input faster, so a match is found
  // only when it is long; its length decides which check gives up.
  for lit in [0, 300, 3000, 30000] {
    for extra in 0..<200 {
      for tail in [5, 12] {
        let input = r[0:lit].to_owned() +
          r[0:4 + extra].to_owned() +
          r[lit:lit + tail].to_owned()
        let frame = compress(input, linked=false, checksum=false)
        assert_eq(decompress(frame), input)
        assert_eq(
          decompress_block(compress_block(input), max_output=input.length()),
          input,
        )
      }
    }
  }
  // Incompressible input: one stored block, its size's top bit set.
  let frame = compress(r[0:4000], linked=false)
  // The block's size is in bytes 7 to 10, after the 7-byte header.
  assert_eq(frame[10].to_int(), 0x80)
}

///|
test "limits stop long lengths and long output" {
  // A literal length of many 255s, and a match length, past max_output.
  let lits = Bytes::makei(2000, i => if i == 0 { b'\xF0' } else { b'\xFF' })
  assert_eq(
    error_kind(() => decompress_block(lits, max_output=1000) |> ignore),
    "LimitExceeded({ resource: Output, needed: None, limit: 1000 })",
  )
  let matches = b"\x1Fa\x01\x00" + Bytes::make(2000, b'\xFF')
  assert_eq(
    error_kind(() => decompress_block(matches, max_output=1000) |> ignore),
    "LimitExceeded({ resource: Output, needed: None, limit: 1000 })",
  )
  // The same in a stream, cut into pieces: the slow path's checks.
  let d = Decoder::make(EndOfInput, None, true)
  d.block_max = 1000
  let slice = FixedArray::make(100, b'\x00')
  assert_eq(
    error_kind(() => d.step(matches[:], slice.mut_view(), end=true) |> ignore),
    "LimitExceeded({ resource: Output, needed: None, limit: 1000 })",
  )
  // max_output of a whole frame.
  let frame = compress(Bytes::make(5000, b'z'))
  assert_eq(
    error_kind(() => decompress(frame, max_output=4999) |> ignore),
    "LimitExceeded({ resource: Output, needed: None, limit: 4999 })",
  )
  assert_eq(decompress(frame, max_output=5000).length(), 5000)
  // A stored block past the declared content size.
  let r = sample(3000, 72, text=false)
  let e = Encoder(content_size=3000, linked=false)
  let a = encode_split(e, r, 3000, 100000).to_fixedarray()
  a[6] = (a[6].to_int() - 1).to_byte()
  let bad = rehash(a, 11)
  assert_eq(error_kind(() => decompress(bad) |> ignore), "ChecksumMismatch")
  // An error found while output waits: the output first, then the error.
  let frame = compress(
    b"abcdefghabcdefghabcdefgh",
    linked=false,
    checksum=false,
  )
  let a = frame.to_fixedarray()
  a[4 + 3 + 4 + 1 + 8] = b'\x09'
  let (out, kind) = decode_split(Decoder(), Bytes::from_array(a[:]), 1000, 3)
  assert_eq(kind, "Corrupt")
  assert_eq(out, b"abcdefgh")
}

///|
test "long matches are decoded through the window, never past it" {
  // "a", then a match one back whose length's 255s add up to nine times
  // what the window holds: copied through it a window at a time.
  let n = 9000
  let block = Bytes::makei(n + 6, i => {
    if i == 0 {
      b'\x1F'
    } else if i == 1 {
      b'a'
    } else if i == 2 {
      b'\x01'
    } else if i == 3 {
      b'\x00'
    } else if i < 4 + n {
      b'\xFF'
    } else if i == 4 + n {
      b'\x00'
    } else {
      b'\x00'
    }
  })
  let out = decompress_block(block, max_output=0x7FFFFFFF)
  assert_eq(out.length(), 1 + 19 + 255 * n)
  assert_true(out.to_array().iter().all(b => b == b'a'))
}

///|
test "a reset encoder starts from its dictionary again" {
  // Linked blocks' history slides over the dictionary in the first frame;
  // the next frame must still see the dictionary itself.
  let dict = b"aaaaaXYZ"
  let e = Encoder(dictionary=dict, checksum=false)
  let first = b"aaaaa123".repeat(8192)
  let a = encode_split(e, first, first.length() + 1, 1 << 20)
  assert_eq(decompress(a, dictionary=dict), first)
  e.reset()
  let second = b"!aaaaa123".repeat(10)
  let b = encode_split(e, second, second.length() + 1, 1 << 20)
  assert_eq(decompress(b, dictionary=dict), second)
  assert_eq(b, compress(second, dictionary=dict, checksum=false))
}
