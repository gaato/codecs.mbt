# gaato/snappy

Snappy compression and decompression in pure MoonBit, for Native, JS, Wasm and
Wasm GC. Use it to read and write Snappy's two formats: the raw format, which
LevelDB and Parquet store, and the framing format of `.sz` files and `snzip`.
Hadoop's and Kafka's Snappy streams use framings of their own, which this
module does not read.

The raw format is compressed and decompressed whole. The framing format is
streamed: input in chunks of any size, output into buffers you choose, and
each chunk's CRC-32C checked. The encoder follows Google's snappy and writes
the same raw bytes. The framed decoder and encoder implement
[`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), so the same
loop drives Zstandard, gzip and the other codecs of
[codecs.mbt](https://github.com/gaato/codecs.mbt).

## Install

```sh
moon add gaato/snappy
```

## Compress and decompress bytes

Pick the function by format: `compress` / `decompress` for the framing format,
`compress_raw` / `decompress_raw` for the raw one.

```mbt check
///|
test "compress and decompress" {
  let text = b"hello, hello, hello, snappy"
  // The framing format (.sz files, `snzip`).
  let framed = @snappy.compress(text)
  assert_eq(@snappy.decompress(framed, max_output=16 * 1024 * 1024), text)
  // The raw format (LevelDB, Parquet), with its length first.
  let raw = @snappy.compress_raw(text)
  assert_eq(@snappy.decompress_raw(raw, max_output=16 * 1024 * 1024), text)
}

///|
test "decode what snappy wrote" {
  let framed = b"\xff\x06\x00\x00sNaPpY\x01\x09\x00\x00\xbb\x1f\x1c\x19hello"
  assert_eq(@snappy.decompress(framed), b"hello")
  assert_eq(@snappy.decompress_raw(b"\x05\x10hello"), b"hello")
}
```

`decompress` and `decompress_raw` have no output cap unless you pass
`max_output`. Set one for input that comes from elsewhere. `decompress_raw`
checks the declared length against `max_output` before it allocates.

## Decode a framed stream as it arrives

Pass `end=true` once the source has run dry, with an empty input if need be,
so that a stream cut short raises `Truncated`. An empty framed input is a
valid empty stream.

```mbt check
///|
/// Decodes what `read` hands over, `None` once it has no more, passing the
/// output to `write` as it is decoded.
fn decode_all(read : () -> Bytes?, write : (Bytes) -> Unit) -> Unit raise {
  let decoder = @snappy.Decoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  for ;; {
    let piece = read()
    let end = piece is None
    let mut input = piece.unwrap_or(b"")[:]
    for ;; {
      let status = decoder.step(input, out.mut_view(), end~)
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
  () => if next < pieces.length() {
    next += 1
    Some(pieces[next - 1])
  } else {
    None
  }
}

///|
test "decode a stream chunk by chunk" {
  let decoded = Buffer()
  decode_all(
    pieces_of([
      b"\xff\x06\x00\x00sNa", b"PpY\x01\x09\x00\x00\xbb\x1f", b"\x1c\x19hello",
    ]),
    bytes => decoded.write_bytes(bytes),
  )
  assert_eq(decoded.to_bytes(), b"hello")
}
```

The decoder reads streams one after another and skips padding and other
skippable chunks. `Decoder(until=EndOfMember)` stops before the next stream's
identifier. `Encoder()` streams the other way: `Continue` takes input, `Flush`
writes what it holds as a chunk, and `Finish` ends the stream.

The raw format has no streaming decoder: its length comes first and a copy may
reach back to the start of the output, so a decoder must hold all of it anyway.
For streams, use the framing format.

## Defaults and limits

| Option | Default | Notes |
| --- | --- | --- |
| `verify_checksums` (`Decoder`) | `true` | `false` skips the CRC-32C check. |
| `until` (`Decoder`) | `EndOfInput` | |
| `max_output` (`decompress`, `decompress_raw`) | none | Raises `LimitExceeded` with `resource: Output` past it. |

The framed decoder holds at most 139 KiB (`decoder_memory_bound()`), and the
encoder 245 KiB (`encoder_memory_bound()`). A compressed chunk longer than
76,494 bytes (the most 64 KiB can compress to) is valid in the format but no
encoder writes one. The decoder refuses it with `LimitExceeded`, resource
`Memory`.

`compress` and `compress_raw` allocate their output at its bound first, so they
abort for inputs near 2 GiB (an array's limit). An `Encoder` streams any length.
`compress_bound(n)` and `raw_compress_bound(n)` give the bounds.

## Errors

A malformed stream raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError(kind, message)`. The decoders never abort on bad input.

| Kind | When |
| --- | --- |
| `Truncated` | The input ends inside a chunk, or inside a raw stream's length. |
| `Corrupt` | Anything else wrong in the stream. |
| `ChecksumMismatch` | A chunk's CRC-32C fails. |
| `LimitExceeded` | A compressed chunk over 76,494 bytes (`resource: Memory`), or more than `max_output` (`resource: Output`). |

A chunk's bytes come out as soon as it is decoded, and `ChecksumMismatch` after
them. `decompress` returns only checked output. **Errors stick:** every later
step raises the same kind until `reset()`.

## Not included

Snappy 1.2's higher compression level (its output decodes here like any
stream), and hardware CRC instructions. For CRC-32C on its own, use
[`gaato/crc`](https://mooncakes.io/docs/gaato/crc).

## Links

- [The format](https://github.com/google/snappy/blob/main/format_description.txt)
  and [its framing](https://github.com/google/snappy/blob/main/framing_format.txt)
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/snappy/RESOURCE_BOUNDS.md)
  and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/snappy/TEST_COVERAGE.md)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md)
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/snappy/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0.
