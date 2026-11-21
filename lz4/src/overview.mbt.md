# gaato/lz4

LZ4 compression and decompression in pure MoonBit, for Native, JS, Wasm and
Wasm GC. Use it to read and write `.lz4` files and LZ4 frames from other
programs, or to decode raw LZ4 blocks inside a container format that records
their sizes.

The frame decoder and encoder stream: they take input in chunks of any size,
write into output buffers you choose, and check every checksum. With the same
options and no dictionary, the encoder writes the bytes the reference `lz4`
1.10.0 writes. Both implement
[`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), so the same
loop drives Zstandard, gzip and the other codecs of
[codecs.mbt](https://github.com/gaato/codecs.mbt).

## Install

```sh
moon add gaato/lz4
```

## Frames or blocks

An LZ4 **frame** (what the `lz4` command writes) carries its own header,
checksums and end. A **block** is bare compressed data: the program that
stores it must also keep its decoded size, or a bound on it.

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

`decompress` has no output cap unless you pass `max_output`. Set one for input
that comes from elsewhere.

## Decode frames as they arrive

Pass `end=true` once the source has run dry, with an empty input if need be,
so that a cut frame, or a source with nothing in it, raises `Truncated`.
The decoder reads frames one after another, as `lz4 -d` does.

```mbt check
///|
/// Decodes what `read` hands over, `None` once it has no more, passing the
/// output to `write` as it is decoded.
fn decode_all(read : () -> Bytes?, write : (Bytes) -> Unit) -> Unit raise {
  let decoder = @lz4.Decoder()
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
  let frame = @lz4.compress(b"one frame, then the next")
  let decoded = Buffer()
  let pieces = [frame[:9].to_owned(), frame[9:].to_owned(), frame]
  decode_all(pieces_of(pieces), bytes => decoded.write_bytes(bytes))
  assert_eq(
    decoded.to_bytes(),
    b"one frame, then the nextone frame, then the next",
  )
}
```

`Decoder(until=EndOfMember)` stops after the first frame and consumes nothing
past it. Legacy frames (`lz4 -l`) end only where the next frame or the input
does, so they raise `Unsupported` in that mode. `frame_info()` gives what the
current frame's header says.

`Encoder()` streams the other way, as the `codec_bytes` loop shows: `Continue`
takes input, `Flush` writes what it holds as a block so the output so far
decodes, and `Finish` ends the frame.

## Defaults and limits

| Option | Default | Notes |
| --- | --- | --- |
| `acceleration` | 1 | Higher is faster and larger. `lz4 --fast=N` is N + 1. |
| `block_size` | `Max64KiB` | The `lz4` command uses `Max4MiB` with `linked=false`. |
| `linked` | `true` | Blocks may refer to the previous 64 KiB. |
| `checksum` | `true` | Content checksum. |
| `block_checksum` | `false` | |
| `content_size` | none | Written in the header when given, and the input is held to it. |
| `max_output` (`decompress`) | none | Raises `LimitExceeded` past it. |
| `max_output` (`decompress_block`) | required | A block does not say its size, so the caller gives its decoded size or a bound. |

The decoder holds at most 256 KiB (`decoder_memory_bound()`), never a whole
block, however large the frame's blocks are. The encoder holds 229 KiB at the
defaults and 8.1 MiB with 4 MiB blocks (`encoder_memory_bound(block_size~)`).
`compress_bound(n)` bounds a frame and `block_compress_bound(n)` a block.

## Dictionaries

`Decoder(dictionary=d)` and `decompress(dictionary=d)` read frames written with
`lz4 -D`. A frame that names a dictionary id in its header raises
`DictionaryRequired` without one. `Encoder(dictionary=…, dictionary_id=…)`
writes such frames. With a dictionary, the encoder's output differs slightly
from the reference `lz4`, but both decode the same.

## Errors

A malformed frame raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError(kind, message)`. The decoders never abort on bad input.

| Kind | When |
| --- | --- |
| `Truncated` | The input ends inside a frame. |
| `Corrupt` | The input is not valid LZ4. |
| `ChecksumMismatch` | A header, block or content checksum fails, or the content size does not match. |
| `Unsupported` | A version, block size or reserved bit the format does not define, or a legacy frame under `until=EndOfMember`. |
| `DictionaryRequired` | The frame names a dictionary and none was given. |
| `TrailingData` | Bytes after the last frame start no frame. |
| `LimitExceeded` | More than `max_output`. |

A block's bytes come out as they are decoded, before the checksums that cover
them, so a streaming caller may hold bytes when a checksum fails. `decompress`
returns only checked output. **Errors stick:** every later step raises the same
kind until `reset()`.

## Not included

High-compression levels (lz4hc, `lz4 -3` to `-12`), compressing to fit a given
output size, partial block decoding, dictionary training and multithreaded
compression. Output from any of them decodes here.

## Links

- [The frame format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md)
  and [the block format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md)
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/lz4/RESOURCE_BOUNDS.md)
  and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/lz4/TEST_COVERAGE.md)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md)
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/lz4/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0. The compressor in `src/encode.mbt` follows
[lz4](https://github.com/lz4/lz4)'s `LZ4_compress_generic`, under the BSD
2-Clause license; see `LICENSE-lz4`.
