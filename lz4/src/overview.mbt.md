# gaato/lz4

LZ4 in pure MoonBit, for Native, JS, Wasm and Wasm GC: its frame format, streamed, with its checksums, dictionaries, content sizes, skippable frames and legacy frames, and its block format, whole. The encoder is lz4's fast one, and without a dictionary writes the bytes lz4 1.10.0 writes for the same options.

## Install

```sh
moon add gaato/lz4
```

## Usage

One shot:

```mbt check
///|
test "compress and decompress" {
  let text = b"hello, hello, hello, lz4"
  let frame = @lz4.compress(text)
  assert_eq(@lz4.decompress(frame, max_output=16 * 1024 * 1024), text)
  // A block on its own: the caller keeps its size, or a bound of it.
  let block = @lz4.compress_block(text)
  assert_eq(@lz4.decompress_block(block, max_output=text.length()), text)
}

///|
test "decode what lz4 wrote" {
  // `lz4` of "hello hello hello hello hello".
  let frame = b"\x04\x22\x4d\x18\x64\x40\xa7\x0f\x00\x00\x00\x6ehello \x06\x00\x50hello\x00\x00\x00\x00\x79\xb1\xff\xf9"
  assert_eq(@lz4.decompress(frame), b"hello hello hello hello hello")
}
```

Streaming: feed input as it arrives, take output in slices of the size you choose.

```mbt check
///|
fn decode_all(chunks : Array[Bytes], sink : (BytesView) -> Unit) -> Unit raise {
  let decoder = @lz4.Decoder()
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
  let frame = @lz4.compress(b"one frame, then the next")
  let decoded = Buffer()
  decode_all([frame[:9].to_owned(), frame[9:].to_owned(), frame], bytes => {
    decoded.write_bytes(bytes.to_owned())
  })
  assert_eq(
    decoded.to_bytes(),
    b"one frame, then the nextone frame, then the next",
  )
}
```

`Encoder()` streams the other way: `Continue` takes input, `Flush` writes what it holds as a block, so that the output so far decodes to the input so far, and `Finish` ends the frame. Both keep the rules of [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), and implement its `Decode` and `Encode`.

## What it decodes

Every LZ4 frame: independent and linked blocks of 64 KiB to 4 MiB, compressed and stored, with block checksums, the content checksum and the content size, all checked; skippable frames; legacy frames (`lz4 -l`), which end where the next frame's magic number or the input does; and frames one after another, as `lz4 -d` reads them. `Decoder(until=EndOfMember)` stops after the first frame, a skippable one included, and consumes nothing past it; a legacy frame, whose end shows only after it, raises `Unsupported` under it. `frame_info()` gives what the frame's header says. A block's bytes come out as they are decoded, before the checksums that cover them are checked, as the contract has provisional output (`decompress` returns only checked output).

`Decoder(dictionary=d)` and `decompress(dictionary=d)` decode frames written with a dictionary (`lz4 -D`): its last 64 KiB come before the frame's first block, or before every block when they are independent. A frame that names a dictionary in its header (`frame_info().dictionary_id`) raises `DictionaryRequired` without one; `lz4 -D` names none. Legacy frames take none.

`decompress_block` decodes a block on its own, as `LZ4_decompress_safe` does, given a bound of its size, and with a dictionary as `LZ4_decompress_safe_usingDict`. A block must end with literals, as the format has it.

## Encoding

The encoder is lz4's fast compressor (`LZ4_compress_fast`) and its frame writer: with the same options, its frames are lz4 1.10.0's to the byte, for independent and for linked blocks of every size, with block checksums and the content size, at every `acceleration` (`lz4 --fast=N` is N + 1), and so are its blocks; the tests hold it to that on every target, and `lz4 -d` and lz4_flex decode every stream. With a dictionary, its output differs from lz4's, by under 0.1 % of the size on the test data either way: it indexes every position of the dictionary, where lz4 skips some, and keeps its history differently. A block is stored uncompressed when compressing does not make it smaller, as lz4 stores it.

The defaults are lz4's library's: 64 KiB linked blocks, and the content checksum, which `lz4` the command writes too; the command uses 4 MiB independent blocks (`block_size=Max4MiB, linked=false`). `content_size` writes the size in the header and holds the input to it. `dictionary` and `dictionary_id` write frames for `lz4 -D`, naming the dictionary in the header when given an id. `compress_bound(n)` is the most a frame of `n` bytes takes, 8 more for each `Flush`; `block_compress_bound(n)` is lz4's `LZ4_COMPRESSBOUND`.

Not included: lz4's high-compression levels (lz4hc, `lz4 -3` to `-12`) and its compressor that fills a given output (`LZ4_compress_destSize`); decoding a block partly (`LZ4_decompress_safe_partial`); dictionary training, which lz4 leaves to zstd; and multithreaded compression. Their output decodes here like any LZ4.

## Memory

The decoder holds a window of 256 KiB at most (`decoder_memory_bound()`), grown as output needs it: never a whole block, however large the frame's blocks are, since a match reaches no more than 64 KiB back. The encoder holds a block of input, the 64 KiB before it for linked blocks or a dictionary, the hash tables and a block's output: 229 KiB at the defaults, 8.1 MiB for 4 MiB blocks, within `encoder_memory_bound(block_size~)`. `memory_usage()` reports each.

## Errors

A malformed frame raises `CodecError(kind, message)` with `Truncated`, `Corrupt`, `ChecksumMismatch` (the header's, a block's or the content's checksum, or a content size the frame does not hold), `Unsupported` (a version, block size or reserved bit the format has not defined), `DictionaryRequired`, or `TrailingData` (bytes after the last frame that begin none); `max_output` raises `LimitExceeded` past it (a negative one counts as 0). The decoders do not abort.

A step that raises first hands out the output before the error, and `last_consumed()` and `last_produced()` count what that step took and wrote: a corrupt stream gives the same output, then the same error, however it is split. On `TrailingData`, `last_consumed()` stops at the end of the stream.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/lz4/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [The frame format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md) and [the block format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md) that `Decoder` and `Encoder` keep
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/lz4/RESOURCE_BOUNDS.md) and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/lz4/TEST_COVERAGE.md)

## License

Apache-2.0. The compressor in `src/encode.mbt` follows [lz4](https://github.com/lz4/lz4)'s `LZ4_compress_generic`, under the BSD 2-Clause license; see `LICENSE-lz4`.
