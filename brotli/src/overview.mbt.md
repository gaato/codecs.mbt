# gaato/brotli

A streaming Brotli (RFC 7932) decoder and encoder in pure MoonBit, for Native, JS, Wasm and Wasm GC. Both take input in chunks of any size, write output into slices of any size, and have memory bounds you can query before construction. They fit an HTTP client's or server's `br` content coding as well as a whole file.

## Install

```sh
moon add gaato/brotli
```

## Usage

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

Encoding works the same way. `Flush` makes the output so far decode to the input so far, say to send one part of an HTTP response; `Finish` ends the stream. A flush ends the meta-block in progress and pads to a byte with an empty metadata block, as the reference encoder's does; a flush with nothing new since the last writes nothing, and one before any input writes the stream header and that padding, 2 bytes.

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

`Decoder` and `Encoder` implement `Decode` and `Encode` from [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), the contract the codecs of [codecs.mbt](https://github.com/gaato/codecs.mbt) share, so code written once against it drives them. Errors are `gaato/codec`'s `CodecError(kind, message)`, the same for every codec there; `gaato/codec_bytes` re-exports it, so that one import names it.

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

## What it decodes

Every RFC 7932 stream, including the static dictionary and its 121 transforms. Input comes in chunks of any size, down to one byte, and output goes into slices of any size, under the rules of [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes). The rules the decoder applies to what it reads and its verdict on a prefix code's lengths are proved against RFC 7932; its decoding tables and the encoder's codes, made as libdeflate makes them, are tested, not proved; [PROOFS.md](https://github.com/gaato/codecs.mbt/blob/main/brotli/PROOFS.md) lists what is proved and what is trusted.

An LZ77 dictionary (RFC 9841 section 3.2), given to `Decoder(dictionary=d)` or `decompress(dictionary=d)` as a `Dictionary` of raw bytes, lets a stream copy from it, as `brotli -D` writes them and RFC 9842's `dcb` coding uses one: distances just past the window's reach address the dictionary from its end, and the static dictionary's words come after them. A copy that would run past the dictionary's end raises `Corrupt`, as google/brotli's decoder refuses it (RFC 9841 has it go on into the window, which a full window no longer holds).

Not included: the rest of Shared Brotli (RFC 9841): serialized shared dictionaries, with their own words and transforms, its large window and its framing format. A large-window stream raises `Corrupt`.

## Encoding

`Encoder(quality=4)` and `compress(input, quality=4)` trade encoding time for size. Quality 4 is the default: lazy LZ77 and one prefix code per meta-block. Qualities 5 through 9 use google/brotli's hashers, static dictionary, block splitting and context models. Values are clamped to 0..11; 0..3 select 4, and 10..11 select 9. The encoder never raises.

At qualities 5..9, when the length is known, pass `Encoder(size_hint=n)` to obtain the same output as `compress` at the same quality and window. `compress` supplies its input length automatically. The hint steers parameter choices; it is neither written into the stream nor checked, so a wrong hint still produces a valid stream whose bytes may differ. Hints are clamped to 0..1 GiB; zero selects the same mode as an omitted hint. Quality 4 ignores hints.

Without a hint, qualities 5..9 follow the reference CLI's stdin mode, processing input on a fixed 512 KiB read schedule. Output is independent of caller input and output splits in either mode. Qualities 5..9 keep the requested `window_bits`; quality 4 reduces a one-shot stream's declared window to what the input needs, preserving its default output.

`Encoder(dictionary=d)` and `compress(dictionary=d)` let matches copy from an LZ77 dictionary as `brotli -D` writes them, for RFC 9842's `dcb` coding: at a distance past the window's reach, however far into the stream. The dictionary builds the index encoders search it with once, the first time, and every encoder given it shares that (`Dictionary::memory_usage`).

## Memory

The decoder's memory is the window (at most 16 MiB, and no more than the output so far) plus tables of at most 1.3 MiB; `memory_usage()` reports it, and `decoder_memory_bound(max_window_bits~)` gives its most before you make a decoder. `Decoder(max_window_bits=n)` refuses streams that need a window over `2^n - 16` bytes with `LimitExceeded`, saying how much the stream needs.

At quality 4 the encoder holds its window (`Encoder(window_bits=n)`, 22 by default: 4 MiB, growing with input) plus a 64 KiB meta-block, its output and 855 KiB of fixed tables. Qualities 5..9 also hold delayed commands, larger hash tables, a 512 KiB input buffer and a reference ring after its first wrap. `memory_usage()` reports owned buffers; `encoder_memory_bound(quality~, window_bits~, size_hint?)` bounds them and coding scratch. Higher qualities can use substantially more memory; see [resource bounds](https://github.com/gaato/codecs.mbt/blob/main/brotli/RESOURCE_BOUNDS.md). `compress_bound(n)` bounds whole-stream output.

## Errors

Every malformed stream raises `CodecError(kind, message)` with `Truncated`, `Corrupt` or `TrailingData` (bytes after the stream); `decompress(max_output=n)` raises `LimitExceeded` past `n` bytes. The decoder does not abort.

A step that raises first hands out the output that comes before the error (answering `NeedMoreOutput` while it does not fit), and `last_consumed()` and `last_produced()` count what that step took and wrote: a corrupt stream gives the same output, then the same error, however it is split. On `TrailingData`, `last_consumed()` stops at the end of the stream.

## When to use it

gaato/brotli fits Brotli that arrives in pieces or comes from anyone. `Decoder` takes input in pieces down to one byte, writes into your slices and holds its window and at most 1.3 MiB of tables. Its decoding rules are proved against RFC 7932. Both codecs run on Native, JS, Wasm and Wasm GC.

The [comparison](https://github.com/gaato/codecs.mbt/blob/main/bench/README.md#compression-codecs-against-other-implementations) gives decoding and default-encoding measurements against other MoonBit implementations; the [encoding notes](https://github.com/gaato/codecs.mbt/blob/main/brotli/docs/compression.md) compare qualities with the reference.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/brotli/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/brotli/CHANGELOG.md)
- [Comparison with other MoonBit implementations](https://github.com/gaato/codecs.mbt/blob/main/bench/README.md#compression-codecs-against-other-implementations): what each supports, checks and holds, and how fast it decodes and encodes
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md) that `Decoder` and `Encoder` keep
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/brotli/RESOURCE_BOUNDS.md): every limit and the tests that hold it
- [Encoding comparison](https://github.com/gaato/codecs.mbt/blob/main/brotli/docs/compression.md): quality settings, reference output and measurements
- [Proofs](https://github.com/gaato/codecs.mbt/blob/main/brotli/PROOFS.md) and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/brotli/TEST_COVERAGE.md)

## License

Apache-2.0, with the quality 5..9 encoder port from [google/brotli](https://github.com/google/brotli) under MIT (`LICENSE-encoder`). The static dictionary in `src/static_data.mbt` is also MIT; see `LICENSE-dictionary`.
