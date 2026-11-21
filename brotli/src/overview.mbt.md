# gaato/brotli

Brotli (RFC 7932) compression and decompression in pure MoonBit, for Native,
JS, Wasm and Wasm GC. Use it for an HTTP client's or server's `br` content
coding, or to compress static files ahead of time at the highest quality.

The decoder and the encoder take input in chunks of any size and write into
output buffers you choose. Their memory bounds can be queried before you make
one. Both implement
[`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), so the same
loop drives gzip, Zstandard and the other codecs of
[codecs.mbt](https://github.com/gaato/codecs.mbt).

## Install

```sh
moon add gaato/brotli
```

## Compress and decompress bytes

```mbt check
///|
test "compress and decompress" {
  let text = b"hello, hello, hello, brotli"
  let compressed = @brotli.compress(text) // quality 4
  assert_eq(@brotli.decompress(compressed), text)
}

///|
test "decompress with an output cap" {
  let compressed = b"\x0b\x02\x80hello\x03" // compress(b"hello")
  let text = @brotli.decompress(compressed, max_output=16 * 1024 * 1024)
  assert_eq(text, b"hello")
}
```

`decompress` has no output cap unless you pass `max_output`. Set one for input
that comes from elsewhere.

## Decode a stream as it arrives

Keep one `Decoder` for the stream. Advance the input by `last_consumed()`, take
`last_produced()` bytes of output, and pass `end=true` once the source has run
dry, with an empty input if need be, so that a stream cut short, or a source
with nothing in it, raises `Truncated`.

```mbt check
///|
/// Decodes what `read` hands over, `None` once it has no more, passing the
/// output to `write` as it is decoded.
fn decode_all(read : () -> Bytes?, write : (Bytes) -> Unit) -> Unit raise {
  let decoder = @brotli.Decoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  for ;; {
    let piece = read()
    let end = piece is None
    let mut input = piece.unwrap_or(b"")[:]
    for ;; {
      let status = decoder.step_into(input, out, end~)
      input = input[decoder.last_consumed():]
      write(Bytes::from_array(out[:decoder.last_produced()]))
      match status {
        Done => return
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
  }
}

///|
/// A source that hands over `pieces` one by one, then `None`.
fn pieces_of(pieces : Array[Bytes]) -> () -> Bytes? {
  let mut next = 0
  () => {
    if next < pieces.length() {
      next += 1
      Some(pieces[next - 1])
    } else {
      None
    }
  }
}

///|
test "decode a stream chunk by chunk" {
  let decoded = Buffer()
  decode_all(pieces_of([b"\x0b\x02", b"\x80hel", b"lo\x03"]), bytes => {
    decoded.write_bytes(bytes)
  })
  assert_eq(decoded.to_bytes(), b"hello")
}
```

Brotli has no framing, so an input holds one stream. To read a stream followed
by data of your own, make the decoder with `until=EndOfMember`. It stops right
after the stream, and `input[decoder.last_consumed():]` is what follows.

## Encode a stream

`Flush` makes the output so far decodable, say to send one part of an HTTP
response. `Finish` ends the stream. A flush with nothing new since the last one
writes nothing. The encoder never raises.

```mbt check
///|
/// Compresses each part `read` hands over and flushes it, so that the output
/// so far decodes in full; at `None` it finishes the stream, which an empty
/// source needs too.
fn encode_parts(read : () -> Bytes?, write : (Bytes) -> Unit) -> Unit {
  let encoder = @brotli.Encoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  for ;; {
    let piece = read()
    let action : @brotli.EncodeAction = if piece is None {
      Finish
    } else {
      Flush
    }
    let mut input = piece.unwrap_or(b"")[:]
    for ;; {
      let status = encoder.step_into(input, out, action~)
      input = input[encoder.last_consumed():]
      write(Bytes::from_array(out[:encoder.last_produced()]))
      match status {
        Done => return
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
  }
}

///|
test "encode a stream part by part" {
  let encoded = Buffer()
  encode_parts(pieces_of([b"<html>", b"<body>hello</body>", b"</html>"]), bytes => {
    encoded.write_bytes(bytes)
  })
  let decoded = @brotli.decompress(encoded.to_bytes())
  assert_eq(decoded, b"<html><body>hello</body></html>")
}
```

The output depends only on the input, the options and where `Flush` falls,
never on how the input or output is split.

## Choosing a quality

| Quality | What it does | Typical use |
| --- | --- | --- |
| 0–1 | Fast fragment encoders | Responses compressed on the fly where CPU matters most |
| 2–3 | Simple hashers, greedy parsing | |
| **4** (default) | Lazy LZ77, one prefix code per meta-block | General use |
| 5–9 | Block splitting and context models | |
| 10–11 | Binary-tree matching and cost-based parsing: much slower, smallest output | Static assets compressed once |

Qualities 0–3 and 5–11 follow the reference encoder. Values outside 0–11 are
clamped. When you stream with `Encoder` and know the input length, pass
`size_hint=n` to get the same bytes `compress` would write. The
[encoding notes](https://github.com/gaato/codecs.mbt/blob/main/brotli/docs/compression.md)
give sizes and speeds per quality.

## Defaults and limits

| Option | Default | Notes |
| --- | --- | --- |
| `quality` (`compress`, `Encoder`) | 4 | 0 to 11. |
| `window_bits` (`compress`, `Encoder`) | 22 (4 MiB) | Clamped to 10–24. |
| `max_window_bits` (`decompress`, `Decoder`) | 24 (16 MiB, Brotli's largest) | A stream that needs a larger window raises `LimitExceeded`. |
| `max_output` (`decompress`) | none | Raises `LimitExceeded` with `resource: Output` past it. |
| `until` (`Decoder`) | `EndOfInput` | |

A decoder holds its window, which is never more than the output so far, plus at
most 1.3 MiB of tables. `decoder_memory_bound(max_window_bits~)` gives the
bound before you make one. `encoder_memory_bound(quality~, window_bits~, size_hint?)`
bounds an encoder, and `compress_bound(n, quality~, window_bits~)` bounds the
output. `memory_usage()` reports the current amount on either.
[Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/brotli/RESOURCE_BOUNDS.md)
lists every limit.

## Dictionaries

An LZ77 dictionary of raw bytes (RFC 9841 section 3.2), given as a `Dictionary`
to `Decoder`, `Encoder`, `compress` or `decompress`, lets a stream copy from it.
`brotli -D` writes such streams, and RFC 9842's `dcb` coding uses them. The rest
of Shared Brotli (serialized shared dictionaries, the large window and its
framing) is not included, and a large-window stream raises `Corrupt`.

## Errors

A malformed stream raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError(kind, message)`. The decoder never aborts on bad input.

| Kind | When |
| --- | --- |
| `Truncated` | The input ends inside the stream. |
| `Corrupt` | The input is not a valid stream, or a copy runs past the end of the dictionary. |
| `TrailingData` | Bytes follow the stream (with the default `EndOfInput`). |
| `LimitExceeded` | A window over `max_window_bits` (`resource: Memory`), or more than `max_output` from `decompress` (`resource: Output`). |

A step that raises first hands out the output that comes before the error.
**Errors stick:** every later step raises the same kind until `reset()`.

## Links

- [Comparison with other MoonBit implementations](https://github.com/gaato/codecs.mbt/blob/main/bench/README.md#compression-codecs-against-other-implementations)
- [Encoding notes](https://github.com/gaato/codecs.mbt/blob/main/brotli/docs/compression.md):
  each quality's algorithm and its output against the reference encoder
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/brotli/RESOURCE_BOUNDS.md),
  [proofs](https://github.com/gaato/codecs.mbt/blob/main/brotli/PROOFS.md) and
  [test coverage](https://github.com/gaato/codecs.mbt/blob/main/brotli/TEST_COVERAGE.md)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md)
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/brotli/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0, with the quality 5..11 encoder port from
[google/brotli](https://github.com/google/brotli) under MIT (`LICENSE-encoder`).
The static dictionary in `src/static_data.mbt` is also MIT; see
`LICENSE-dictionary`.
