# gaato/zstd

A streaming Zstandard (RFC 8878) decoder in pure MoonBit. Native, JS, Wasm and Wasm GC.

```fish
moon add gaato/zstd
```

One shot:

```mbt check
///|
test "decompress a whole stream" {
  let compressed = b"\x28\xb5\x2f\xfd\x20\x05\x29\x00\x00\x68\x65\x6c\x6c\x6f" // zstd.compress(b"hello")
  let text = @zstd.decompress(compressed, max_output=16 * 1024 * 1024)
  assert_eq(text, b"hello")
}
```

Streaming: feed input as it arrives, take output in slices of the size you choose. A stream may hold several frames and nothing marks the last one, so say `end=true` with the last input.

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

## What it does

- Decodes every RFC 8878 frame without a dictionary: raw, RLE and compressed blocks, Huffman-coded literals (one or four streams, with or without a new tree), every FSE table mode, and the content checksum (XXH64). A stream may hold several frames, and skippable frames among them, as the `zstd` tool writes them.
- Takes input in chunks of any size, down to one byte, and writes output into buffers of any size; the same `step` / `Status` shape as `moonbit-community/flate`.
- Memory is the window (at most the frame's `Window_Size`, and no more than its output so far), one compressed block of at most 128 KiB and its literals, plus about 11 KiB of tables. `Decoder(max_window_bits=n)` refuses frames that need a window over `2^n` bytes, before allocating anything; the default 27 (128 MiB) is the reference decoder's.
- Every malformed stream raises `ZstdError(kind, message)`: `Truncated`, `Corrupt` (including bytes after the last frame), `ChecksumMismatch`, `WindowTooLarge`, `DictionaryUnsupported` or `OutputLimitExceeded`. It does not abort.

Not included: an encoder, and dictionaries (RFC 8878 says the `zstd` content coding should not use one; a frame that names one raises `DictionaryUnsupported`).

## License

Apache-2.0. The test frames under `testdata/upstream` come from [facebook/zstd](https://github.com/facebook/zstd) under its BSD license; see `NOTICE`.
