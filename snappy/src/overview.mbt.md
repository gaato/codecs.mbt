# gaato/snappy

Snappy in pure MoonBit, for Native, JS, Wasm and Wasm GC: its raw format, compressed and decompressed whole, and its framing format, streamed, with each chunk's CRC-32C checked. The encoder follows Google's snappy and writes what it writes, but for no input, where it writes the identifier that every framed stream begins with.

## Install

```sh
moon add gaato/snappy
```

## Usage

One shot, in either format:

```mbt check
///|
test "compress and decompress" {
  let text = b"hello, hello, hello, snappy"
  // The framing format (.sz, `snzip`, Hadoop and Kafka's framed Snappy).
  let framed = @snappy.compress(text)
  assert_eq(@snappy.decompress(framed, max_output=16 * 1024 * 1024), text)
  // The raw format (LevelDB, Parquet, Cassandra), with its length first.
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

Streaming the framing format: feed input as it arrives, take output in slices of the size you choose.

```mbt check
///|
fn decode_all(chunks : Array[Bytes], sink : (BytesView) -> Unit) -> Unit raise {
  let decoder = @snappy.Decoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  for i, chunk in chunks {
    let mut input = chunk[:]
    for ;; {
      let status = decoder.step(
        input,
        out.mut_view(),
        end=i == chunks.length() - 1,
      )
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
    [b"\xff\x06\x00\x00sNa", b"PpY\x01\x09\x00\x00\xbb\x1f", b"\x1c\x19hello"],
    bytes => decoded.write_bytes(bytes.to_owned()),
  )
  assert_eq(decoded.to_bytes(), b"hello")
}
```

`Encoder()` streams the other way, under the same rules: `Continue` takes input, `Flush` writes what it holds as a chunk, so that the output so far decodes to the input so far, and `Finish` ends the stream. Both keep the rules of [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), and implement its `Decode` and `Encode`.

## What it decodes

Every raw stream, and every framed stream an encoder writes: compressed and uncompressed chunks, padding and the other skippable chunks (0x80 to 0xfe), and streams one after another, as the format allows. `Decoder(until=EndOfMember)` stops before the identifier of a stream that follows data, without taking any of it. A chunk's bytes come out as soon as it is decoded, and `ChecksumMismatch` after them when its CRC-32C fails, as the contract has provisional output (`decompress` returns only checked output); `Decoder(verify_checksums=false)` skips the check. No bytes at all are the empty stream, as the snap crate writes it for no input.

The decoder holds a compressed chunk's body whole, up to 76,494 bytes: what 64 KiB compresses to at most, as the snap crate and golang/snappy hold. The format allows longer compressed chunks that still decode to 64 KiB, which no encoder writes; one raises `LimitExceeded` with resource `Memory`, and its length as `needed`.

The raw format is whole only: its length comes first, and a copy may reach back to the start of the output, so a decoder must hold all of it anyway. For streams, use the framing format.

## Encoding

The encoder is snappy 1.1's: each 64 KiB fragment on its own, with a hash table of up to 2^14 entries and the same skipping of incompressible input, so its raw streams are snappy's to the byte. Its framed chunks are stored uncompressed when compressing saves less than an eighth, as snappy's framing writers do. On the test data, its raw and framed output are the snap crate's, to the byte, but for no input: the snap crate writes nothing, and ours writes the identifier alone, since the format has every stream begin with it. The encoder never raises. `compress_raw` and `compress` allocate their output at its bound first, so inputs whose bound passes 2^31 - 1 bytes, the most an array holds, abort (over 1,840,700,242 bytes for `compress_raw`, 2,147,221,517 for `compress`); an `Encoder` streams any length.

`compress_bound(n)` and `raw_compress_bound(n)` are the most each format writes for `n` bytes; `Flush` adds 8 bytes to the first.

Not included: the encoder's levels of snappy 1.2 (level 2 searches harder, and decodes as any stream does), which Google's snappy has only in C++ so far; hardware CRC instructions, which MoonBit does not reach; and a streaming raw decoder, for the reason above. For CRC-32C itself, use [`gaato/crc`](https://mooncakes.io/docs/gaato/crc).

## Memory

`decompress_raw` checks the length a stream declares against `max_output` and against 22 times the stream's size, the most a stream can describe, before it allocates the output. The framing decoder holds a chunk's body and its decoded bytes, at most 139 KiB (`decoder_memory_bound()`), and the encoder 64 KiB of input, a chunk's output and the hash table, 245 KiB (`encoder_memory_bound()`); `memory_usage()` reports each.

## Errors

A malformed framed stream raises `CodecError(kind, message)` with `Truncated` (the input ends inside a chunk), `Corrupt` or `ChecksumMismatch` (a chunk's CRC-32C); a raw stream raises `Truncated` when the input ends inside its length, and `Corrupt` for anything else wrong in it, cut short or not, as snappy refuses it. A compressed chunk over 76,494 bytes raises `LimitExceeded` with `resource: Memory`, and `max_output` raises `LimitExceeded` with `resource: Output` past it (a negative one counts as 0). The decoders do not abort. Errors stick: later steps raise the same kind until `reset`.

A step that raises first hands out the output before the error, the bytes of a chunk decoded before it breaks off included, and `last_consumed()` and `last_produced()` count what that step took and wrote: a corrupt stream gives the same output, then the same error, however it is split.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/snappy/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [The format](https://github.com/google/snappy/blob/main/format_description.txt) and [its framing](https://github.com/google/snappy/blob/main/framing_format.txt)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md) that `Decoder` and `Encoder` keep
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/snappy/RESOURCE_BOUNDS.md) and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/snappy/TEST_COVERAGE.md)

## License

Apache-2.0.
