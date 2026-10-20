# gaato/brotli

A streaming Brotli (RFC 7932) decoder and encoder in pure MoonBit. Native, JS, Wasm and Wasm GC.

```fish
moon add gaato/brotli
```

One shot:

```mbt check
///|
test "decompress a whole stream" {
  let compressed = b"\x0b\x02\x80hello\x03" // brotli.compress(b"hello")
  let text = @brotli.decompress(compressed, max_output=16 * 1024 * 1024)
  assert_eq(text, b"hello")
}

///|
test "compress and decompress" {
  let text = b"hello, hello, hello, brotli"
  let compressed = @brotli.compress(text)
  assert_eq(@brotli.decompress(compressed), text)
}
```

Streaming: feed input as it arrives, take output in slices of the size you choose.

```mbt check
///|
fn decode_all(chunks : Array[Bytes], sink : (BytesView) -> Unit) -> Unit raise {
  let decoder = @brotli.Decoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  for i, chunk in chunks {
    let mut input = chunk[:]
    for ;; {
      let status = decoder.step_into(input, out, end=i == chunks.length() - 1)
      input = input[decoder.last_consumed():]
      sink(Bytes::from_array(out[:decoder.last_produced()]))
      match status {
        Done => return
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
  }
}

///|
test "decode a stream chunk by chunk" {
  let decoded = Buffer()
  decode_all([b"\x0b\x02", b"\x80hel", b"lo\x03"], bytes => {
    decoded.write_bytes(bytes.to_owned())
  })
  assert_eq(decoded.to_bytes(), b"hello")
}
```

Encoding works the same way. `Flush` makes the output so far decode to the input so far, say to send one part of an HTTP response; `Finish` ends the stream.

```mbt check
///|
fn encode_parts(parts : Array[Bytes], sink : (BytesView) -> Unit) -> Unit {
  let encoder = @brotli.Encoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  for i, part in parts {
    let action : @brotli.EncodeAction = if i == parts.length() - 1 {
      Finish
    } else {
      Flush
    }
    let mut input = part[:]
    for ;; {
      let status = encoder.step_into(input, out, action~)
      input = input[encoder.last_consumed():]
      sink(Bytes::from_array(out[:encoder.last_produced()]))
      if status is (Done | NeedMoreInput) {
        break
      }
    }
  }
}

///|
test "encode a stream part by part" {
  let encoded = Buffer()
  encode_parts([b"<html>", b"<body>hello</body>", b"</html>"], bytes => {
    encoded.write_bytes(bytes.to_owned())
  })
  let decoded = @brotli.decompress(encoded.to_bytes())
  assert_eq(decoded, b"<html><body>hello</body></html>")
}
```

`Decoder` and `Encoder` implement `Decode` and `Encode` from [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), the contract the codecs of [codecs.mbt](https://github.com/gaato/codecs.mbt) share, so code written once against it drives them. Errors are `gaato/codec`'s `CodecError(kind, message)`, the same for every codec there.

Brotli has no framing, so an input holds one stream. A decoder made with `until=EndOfMember` stops right after the stream and leaves what follows unread:

```mbt check
///|
test "stop at the end of the stream" {
  let input = b"\x0b\x02\x80hello\x03" + b"what follows"
  let decoder = @brotli.Decoder(until=EndOfMember)
  let out = FixedArray::make(64, b'\x00')
  let status = decoder.step_into(input, out, end=false)
  assert_eq(status, Done)
  assert_eq(Bytes::from_array(out[:decoder.last_produced()]), b"hello")
  assert_eq(input[decoder.last_consumed():], b"what follows")
}
```

## What it does

- Decodes every RFC 7932 stream, including the static dictionary and its 121 transforms.
- Takes input in chunks of any size, down to one byte, and writes output into buffers of any size; the same `step` / `Status` shape as `moonbit-community/flate`.
- Memory is the window (at most 16 MiB, and no more than the output so far) plus tables of at most 1.3 MiB; `memory_usage()` reports it. `Decoder(max_window_bits=n)` refuses streams that need a window over `2^n - 16` bytes with `LimitExceeded`, saying how much the stream needs.
- Every malformed stream raises `CodecError(kind, message)` with `Truncated`, `Corrupt` or `TrailingData` (bytes after the stream); `decompress(max_output=n)` raises `LimitExceeded` past `n` bytes. It does not abort.
- Encodes with greedy LZ77 (lazy by one byte) and one prefix code per meta-block: about google/brotli's quality 4, and close to gzip -6. Its streams decode with google/brotli's decoder (`scripts/crosscheck.py`).
- The encoder's memory is its window (`Encoder(window_bits=n)`, 22 by default: 4 MiB, growing with the input to at most twice what it has taken, and up to a quarter more before it slides) plus a 64 KiB meta-block, its output and about 1 MiB of fixed tables.

Not included: higher-quality encoding (context modeling, block splitting, static dictionary references), and Shared Brotli (RFC 9841): its shared dictionaries, its large window and its framing format. A large-window stream raises `Corrupt`.

## License

Apache-2.0. The static dictionary in `src/static_data.mbt` comes from [google/brotli](https://github.com/google/brotli) under the MIT license; see `LICENSE-dictionary`.
