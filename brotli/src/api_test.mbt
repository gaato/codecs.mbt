///|
/// "Hello, Brotli! " eight times, compressed by the brotli tool.
let hello : Bytes = [
  0x1b, 0x77, 0x00, 0xf8, 0x9d, 0xc9, 0xe3, 0xde, 0x3b, 0x8d, 0x9a, 0xda, 0xa9, 0xa8,
  0xd9, 0xde, 0x90, 0xd2, 0x16, 0x88, 0x50, 0x95, 0xc9, 0x65, 0x08, 0x0b, 0x5d, 0x24,
  0x18, 0x02, 0x34, 0x86, 0x72, 0x3b,
]

///|
test "decompress a whole stream" {
  let text = @utf8.decode(@brotli.decompress(hello))
  inspect(text.length(), content="120")
  inspect(text[0:15], content="Hello, Brotli! ")
}

///|
test "decode a stream chunk by chunk" {
  let decoder = @brotli.Decoder()
  let out = FixedArray::make(16, b'\x00') // at most 16 bytes per slice
  let text = StringBuilder()
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
    text.write_string(
      @utf8.decode(Bytes::from_array(out[:decoder.last_produced()])),
    )
    if status is Done {
      break
    }
  }
  inspect(text.to_string().length(), content="120")
}

///|
test "errors carry a kind and a message" {
  let result = try @brotli.decompress(hello[:20]) catch {
    @codec.CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => "decoded"
  }
  inspect(result, content="Truncated: the stream ends early")
}

///|
test "EndOfMember stops at the end of the stream" {
  let decoder = @brotli.Decoder(until=EndOfMember)
  let out = FixedArray::make(256, b'\x00')
  let input = hello + b"next"
  debug_inspect(decoder.step_into(input, out, end=false), content="Done")
  inspect(input[decoder.last_consumed():], content="b\"next\"")
}

///|
/// Runs any gaato/codec_bytes decoder over `input` whole.
fn[D : @codec_bytes.Decode] decode_with(
  d : D,
  input : BytesView,
) -> Bytes raise {
  let out = FixedArray::make(7, b'\x00')
  let decoded = Buffer()
  let mut rest = input
  for ;; {
    let status = d.step(rest, out.mut_view(), end=true)
    rest = rest[d.last_consumed():]
    decoded.write_bytes(Bytes::from_array(out[:d.last_produced()]))
    if status is Done {
      return decoded.to_bytes()
    }
  }
}

///|
/// Runs any gaato/codec_bytes encoder over `input` whole.
fn[E : @codec_bytes.Encode] encode_with(
  e : E,
  input : BytesView,
) -> Bytes raise {
  let out = FixedArray::make(7, b'\x00')
  let encoded = Buffer()
  let mut rest = input
  for ;; {
    let status = e.step(rest, out.mut_view(), action=Finish)
    rest = rest[e.last_consumed():]
    encoded.write_bytes(Bytes::from_array(out[:e.last_produced()]))
    if status is Done {
      return encoded.to_bytes()
    }
  }
}

///|
test "the codecs implement gaato/codec_bytes" {
  let decoder = @brotli.Decoder()
  let text = decode_with(decoder, hello)
  inspect(text.length(), content="120")
  inspect(@codec_bytes.Decode::memory_usage(decoder) > 0, content="true")
  @codec_bytes.Decode::reset(decoder)
  assert_eq(decode_with(decoder, hello), text)
  let encoder = @brotli.Encoder()
  let stream = encode_with(encoder, text)
  inspect(@codec_bytes.Encode::memory_usage(encoder) > 0, content="true")
  @codec_bytes.Encode::reset(encoder)
  assert_eq(encode_with(encoder, text), stream)
  assert_eq(@brotli.decompress(stream), text)
}
