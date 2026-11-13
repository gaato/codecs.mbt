///|
/// "Hello, zstd! " eight times, compressed by the zstandard Python module.
let hello : Bytes = [
  0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x68, 0xa5, 0x00, 0x00, 0x68, 0x48, 0x65, 0x6c, 0x6c,
  0x6f, 0x2c, 0x20, 0x7a, 0x73, 0x74, 0x64, 0x21, 0x20, 0x01, 0x00, 0x08, 0xd3, 0xfc,
  0x02,
]

///|
test "decompress a whole stream" {
  let text = @zstd.decompress(hello)
  inspect(text.length(), content="104")
  inspect(text[0:13], content="b\"Hello, zstd! \"")
}

///|
test "decode a stream chunk by chunk" {
  let decoder = @zstd.Decoder()
  let out = FixedArray::make(16, b'\x00') // at most 16 bytes per slice
  let text = Buffer()
  let mut input = hello[:]
  // Feed 5 bytes at a time, as if they came from the network.
  let mut chunk = input[0:0]
  for ;; {
    if chunk.length() == 0 {
      chunk = input[:input.length().min(5)]
      input = input[chunk.length():]
    }
    let status = decoder.step_into(chunk, out, end=input.length() == 0)
    chunk = chunk[decoder.last_consumed():]
    text.write_bytesview(Bytes::from_array(out[:decoder.last_produced()])[:])
    if status is Done {
      break
    }
  }
  assert_true(decoder.is_finished())
  inspect(text.length(), content="104")
}

///|
test "errors carry a kind and a message" {
  let result = try @zstd.decompress(hello[:20]) catch {
    @codec.CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => "decoded"
  }
  inspect(result, content="Truncated: the stream ends inside a frame")
}

///|
/// Decodes `input` with any `gaato/codec_bytes` decoder, in 7-byte chunks
/// into 10-byte slices.
fn[D : @codec_bytes.Decode] decode_with(
  decoder : D,
  input : Bytes,
) -> Bytes raise {
  let out = FixedArray::make(10, b'\x00')
  let text = Buffer()
  let mut rest = input[:]
  for ;; {
    let chunk = rest[:rest.length().min(7)]
    let end = chunk.length() == rest.length()
    let status = decoder.step(chunk, out.mut_view(), end~)
    rest = rest[decoder.last_consumed():]
    text.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
    assert_true(decoder.memory_usage() <= (1 << 23) + (2 << 17))
    if status is Done {
      return text.to_bytes()
    }
  }
}

///|
test "the decoder is a gaato/codec_bytes Decode" {
  let decoder = @zstd.Decoder(max_window_bits=23)
  inspect(decode_with(decoder, hello).length(), content="104")
  @codec_bytes.Decode::reset(decoder)
  inspect(decode_with(decoder, hello).length(), content="104")
}

///|
test "until=EndOfMember leaves what follows the first frame" {
  let two = Bytes::from_array([..hello[:], ..hello[:]])
  let decoder = @zstd.Decoder(until=EndOfMember)
  let out = FixedArray::make(256, b'\x00')
  let status = decoder.step_into(two, out, end=true)
  assert_true(status is @zstd.Status::Done)
  inspect(decoder.last_produced(), content="104")
  inspect(two[decoder.last_consumed():] == hello[:], content="true")
}

///|
test "compress and decompress round-trip" {
  let text = b"Hello, zstd! ".repeat(8)
  let frame = @zstd.compress(text)
  assert_eq(@zstd.decompress(frame), text)
  // Levels 1 to 12; others are clamped.
  assert_eq(@zstd.decompress(@zstd.compress(text, level=19)), text)
  // Without the checksum, 4 bytes shorter.
  let unchecked = @zstd.compress(text, checksum=false)
  assert_eq(@zstd.decompress(unchecked), text)
  inspect(frame.length() - unchecked.length(), content="4")
}

///|
/// Encodes `input` with any `gaato/codec_bytes` encoder, in 7-byte chunks
/// into 10-byte slices.
fn[E : @codec_bytes.Encode] encode_with(e : E, input : Bytes) -> Bytes raise {
  let out = FixedArray::make(10, b'\x00')
  let encoded = Buffer()
  let mut rest = input[:]
  for ;; {
    let chunk = rest[:rest.length().min(7)]
    let action : @codec_bytes.EncodeAction = if chunk.length() == rest.length() {
      Finish
    } else {
      Continue
    }
    let status = e.step(chunk, out.mut_view(), action~)
    rest = rest[e.last_consumed():]
    encoded.write_bytes(Bytes::from_array(out[:e.last_produced()]))
    if status is Done {
      return encoded.to_bytes()
    }
  }
}

///|
test "the encoder is a gaato/codec_bytes Encode" {
  let text = b"Hello, zstd! ".repeat(8)
  let encoder = @zstd.Encoder()
  let frame = encode_with(encoder, text)
  assert_eq(@zstd.decompress(frame), text)
  inspect(@codec_bytes.Encode::memory_usage(encoder) > 0, content="true")
  @codec_bytes.Encode::reset(encoder)
  assert_eq(encode_with(encoder, text), frame)
  // Told the content size, it writes what `compress` writes.
  let sized = @zstd.Encoder(content_size=text.length().to_int64())
  assert_eq(encode_with(sized, text), @zstd.compress(text))
}

///|
test "an input that does not match the content size given raises" {
  let encoder = @zstd.Encoder(content_size=3)
  let out = FixedArray::make(64, b'\x00')
  let result = try encoder.step_into(b"four", out, action=Finish) catch {
    @codec.CodecError(kind, _) => Repr(kind).to_string()
  } noraise {
    _ => "encoded"
  }
  inspect(result, content="ChecksumMismatch")
}
