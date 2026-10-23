# gaato/zstd

A streaming Zstandard (RFC 8878) decoder in pure MoonBit, for Native, JS, Wasm and Wasm GC. It takes input in chunks of any size, writes output into slices of any size, and keeps its memory within the window you allow, so it fits an HTTP client's `zstd` content coding as well as a whole file.

## Install

```sh
moon add gaato/zstd
```

## Usage

One shot:

```mbt check
///|
test "decompress a whole stream" {
  let compressed = b"\x28\xb5\x2f\xfd\x20\x05\x29\x00\x00\x68\x65\x6c\x6c\x6f" // zstd.compress(b"hello")
  let text = @zstd.decompress(compressed, max_output=16 * 1024 * 1024)
  assert_eq(text, b"hello")
}
```

Streaming: feed input as it arrives, take output in slices of the size you choose. A stream may hold several frames and nothing marks the last one, so every step says whether its input is the last: `end=false` before, `end=true` with the last input. `Status` is [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes)'s, re-exported: match `Done`, `NeedMoreInput` and `NeedMoreOutput` unqualified, or write `@zstd.Status::Done`.

```mbt check
///|
fn decode_all(chunks : Array[Bytes], sink : (BytesView) -> Unit) -> Unit raise {
  let decoder = @zstd.Decoder(max_window_bits=23) // 8 MiB, as RFC 9659 asks of HTTP
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
  decode_all(
    [b"\x28\xb5\x2f", b"\xfd\x20\x05\x29\x00\x00\x68", b"\x65\x6c\x6c\x6f"],
    bytes => decoded.write_bytes(bytes.to_owned()),
  )
  assert_eq(decoded.to_bytes(), b"hello")
}
```

A frame followed by something else: `until=EndOfMember` stops right after the first frame and consumes nothing past it, so what follows is `input[last_consumed():]`. A skippable frame counts as a frame here.

```mbt check
///|
test "stop after the first frame" {
  let frame = b"\x28\xb5\x2f\xfd\x20\x05\x29\x00\x00\x68\x65\x6c\x6c\x6f"
  let input = Bytes::from_array([..frame[:], ..b"rest"])
  let decoder = @zstd.Decoder(until=EndOfMember)
  let out = FixedArray::make(64, b'\x00')
  let status = decoder.step_into(input, out, end=true)
  assert_true(status is Done)
  assert_eq(Bytes::from_array(out[:decoder.last_produced()]), b"hello")
  assert_eq(input[decoder.last_consumed():], b"rest")
}
```

`Decoder` implements `gaato/codec_bytes`'s `Decode`, so code written against that contract (an HTTP client, a command-line tool) takes it as it takes any other decoder there.

## What it decodes

Every RFC 8878 frame without a dictionary: raw, RLE and compressed blocks, Huffman-coded literals (one or four streams, with or without a new tree), every FSE table mode, and the content checksum (XXH64). A stream may hold several frames, and skippable frames among them, as the `zstd` tool writes them.

Input comes in chunks of any size, down to one byte, and output goes into slices of any size, under the rules of `gaato/codec_bytes`. The header decisions and the Huffman decoding tables are proved against RFC 8878; [PROOFS.md](https://github.com/gaato/codecs.mbt/blob/main/zstd/PROOFS.md) lists what is proved and what is trusted.

Not included: an encoder, and dictionaries (RFC 8878 says the `zstd` content coding should not use one; a frame that names one raises `DictionaryRequired(Some(id))`).

## Memory

Memory is the window (at most the frame's `Window_Size`, and no more than its output so far), one compressed block of at most 128 KiB and its literals, plus about 11 KiB of tables. `Decoder(max_window_bits=n)` refuses frames that need a window over `2^n` bytes, before allocating anything; the default 27 (128 MiB) is the reference decoder's. For HTTP, RFC 9659 asks for 23 (8 MiB). `memory_usage()` reports the window and the block buffers: at most `2^n` bytes plus 256 KiB.

## Errors

Every malformed stream raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s `CodecError(kind, message)`; the decoder does not abort. The kinds:

- `Truncated`: the input ends inside a frame.
- `Corrupt`: the input is not a valid stream.
- `TrailingData`: bytes after the last frame that start no frame.
- `ChecksumMismatch`: the content checksum does not match.
- `LimitExceeded`: a window over `max_window_bits`, with `resource: Memory`; more than `max_output` from `decompress`, with `resource: Output`.
- `DictionaryRequired`: the frame names a dictionary, with its id.

In a `catch` on these functions, `CodecError(kind, _)` and the kinds match unqualified, with no import; to name the types elsewhere, import [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), which re-exports them.

A step that raises first hands out the output that comes before the error (answering `NeedMoreOutput` while it does not fit), and `last_consumed()` and `last_produced()` count what that step took and wrote: a corrupt stream gives the same output, then the same error, however it is split. On `TrailingData`, `last_consumed()` stops at the end of the stream.

## When to use it

gaato/zstd fits zstd that arrives in pieces or comes from anyone. `Decoder` takes input in pieces down to one byte, writes into your slices and holds the window you allow, 128 MiB by default (10.8 MiB at the peak for 256 MiB of output); it allocates nothing from a size a header claims. It agreed with `zstd -d` on all 36 valid and 318 invalid streams of the comparison, checks the content checksum, and its frame headers and Huffman tables are proved against RFC 8878. It runs on Native, JS, Wasm and Wasm GC; it does not compress and takes no dictionary.

Milky2018/zstd, which also compresses and takes dictionaries, takes about 1.9 (Native), 2.1 (Wasm), 2.3 (Wasm GC) and 1.4 (JS) times as long as gaato/zstd on the benchmarks' text.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/zstd/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [Comparison with other MoonBit implementations](https://github.com/gaato/codecs.mbt/blob/main/bench/README.md#compression-codecs-against-other-implementations): what each supports, checks and holds, and how fast it decodes and encodes
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md) that `Decoder` keeps
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/zstd/RESOURCE_BOUNDS.md): every limit and the tests that hold it
- [Proofs](https://github.com/gaato/codecs.mbt/blob/main/zstd/PROOFS.md) and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/zstd/TEST_COVERAGE.md)

## License

Apache-2.0. The test frames under `testdata/upstream` come from [facebook/zstd](https://github.com/facebook/zstd) under its BSD license; see `NOTICE`.
