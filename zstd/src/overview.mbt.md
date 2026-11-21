# gaato/zstd

Zstandard (RFC 8878) compression and decompression in pure MoonBit, for
Native, JS, Wasm and Wasm GC. Use it to decode an HTTP `zstd` response as it
arrives, to compress a file or a response, or to cut a stream into frames
without decoding it.

The decoder and the encoder take input in chunks of any size and write into
output buffers you choose. The decoder's window is bounded by the
`max_window_bits` you allow, its other memory by about 270 KiB, and it
allocates nothing because of a size a header claims. Both
implement [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes),
so the same loop drives gzip, Brotli and the other codecs of
[codecs.mbt](https://github.com/gaato/codecs.mbt).

## Install

```sh
moon add gaato/zstd
```

## Compress and decompress bytes

```mbt check
///|
test "compress and decompress" {
  let text = b"hello, hello, hello, zstd"
  let compressed = @zstd.compress(text) // level 3, as zstd's default
  assert_eq(@zstd.decompress(compressed), text)
  let smaller = @zstd.compress(text, level=12)
  assert_eq(@zstd.decompress(smaller), text)
}

///|
test "decompress with an output cap" {
  let compressed = b"\x28\xb5\x2f\xfd\x20\x05\x29\x00\x00\x68\x65\x6c\x6c\x6f" // compress(b"hello")
  let text = @zstd.decompress(compressed, max_output=16 * 1024 * 1024)
  assert_eq(text, b"hello")
}
```

`decompress` has no output cap unless you pass `max_output`. Set one for input
that comes from elsewhere: a few bytes of zstd can expand to gigabytes.

## Decode a stream as it arrives

Feed input as it comes, and take output in slices of the size you choose. A
stream may hold several frames and nothing marks the last one, so every step
says whether the source has run dry: `end=false` while it has more, `end=true`
once it has none, with an empty input if need be. A stream cut short, or a
source with nothing in it, then raises `Truncated`.

```mbt check
///|
/// Decodes what `read` hands over, `None` once it has no more, passing the
/// output to `write` as it is decoded.
fn decode_all(read : () -> Bytes?, write : (Bytes) -> Unit) -> Unit raise {
  let decoder = @zstd.Decoder(max_window_bits=23) // 8 MiB, as RFC 9659 asks of HTTP
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
      b"\x28\xb5\x2f", b"\xfd\x20\x05\x29\x00\x00\x68", b"\x65\x6c\x6c\x6f",
    ]),
    bytes => decoded.write_bytes(bytes),
  )
  assert_eq(decoded.to_bytes(), b"hello")
}
```

A `Decoder`'s memory is bounded by its window, but its total output is not.
For input from elsewhere, count what `write` receives and stop past your
budget.

To read one frame followed by something else, make the decoder with
`until=EndOfMember`. It stops right after the first frame and consumes nothing
past it, so what follows is `input[decoder.last_consumed():]`.

## Encode a stream

`Encoder` works the same way, with an action in place of `end`. `Flush` makes
the output so far decodable, say to send one part of an HTTP response. `Finish`
ends the frame. A flush costs a 3-byte block header. A flush with nothing new
since the last one writes nothing.

```mbt check
///|
/// Compresses each part `read` hands over and flushes it, so that the output
/// so far decodes in full; at `None` it finishes the frame, which an empty
/// source needs too.
fn encode_parts(read : () -> Bytes?, write : (Bytes) -> Unit) -> Unit raise {
  let encoder = @zstd.Encoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  for ;; {
    let piece = read()
    let action : @zstd.EncodeAction = if piece is None {
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
  let decoded = @zstd.decompress(encoded.to_bytes())
  assert_eq(decoded, b"<html><body>hello</body></html>")
}
```

The frame's bytes depend only on the input, the options and where `Flush`
falls, never on how the input or output is split.

## Defaults and limits

| Option | Default | Notes |
| --- | --- | --- |
| `level` (`compress`, `Encoder`) | 3 | 1 to 22, plus the fast levels -1 down to -131072 (`zstd --fast=N` is level -N). Higher levels search harder and use more memory. |
| `checksum` (`compress`, `Encoder`) | `true` | Writes the XXH64 content checksum. The decoder checks it when present. |
| `content_size` (`Encoder`) | unknown | Give it when known: it is written in the header, and the window and tables shrink to fit. |
| `max_window_bits` (`decompress`, `Decoder`) | 27 (128 MiB) | Frames that need a larger window are refused before anything is allocated. For HTTP, RFC 9659 asks for 23 (8 MiB). |
| `max_output` (`decompress`) | none | Raises `LimitExceeded` with `resource: Output` past it. |
| `until` (`Decoder`) | `EndOfInput` | Decodes every frame. `EndOfMember` stops after the first. |

A decoder holds at most `2^max_window_bits` bytes plus 256 KiB for a block,
plus 13 KiB of tables. `decoder_memory_bound(max_window_bits=n)` gives that
bound before you make one, and `memory_usage()` reports the current amount. For
input of unknown size, an encoder holds about 3.1 MiB at level 1, 6.8 MiB at
level 3 and 50 MiB at level 12. `encoder_memory_bound(level~, content_size?)`
gives the bound for any level. `compress_bound(n)` is the most `compress`
writes for `n` bytes.

## Dictionaries

Pass a `Dictionary` to `Decoder`, `Encoder`, `compress` or `decompress`.
`Dictionary::parse(bytes)` reads a dictionary in the format `zstd --train`
writes, and `Dictionary::raw(bytes)` takes plain content, as RFC 9842's `dcz`
coding does. Frames made with `zstd -D` decode, and frames written here decode
with `zstd -d -D`. Training dictionaries is not included.

## Read frames without decoding them

`inspect_frame` reads the header of the frame at the start of some bytes.
`frame_size` walks the block headers to where the frame ends, so you can cut a
stream into frames, or check that a frame is whole, cheaply. `skippable_frame`
and `read_skippable_frame` write and read frames that carry your own bytes,
which every decoder skips.

```mbt check
///|
test "frames, read without decoding them" {
  let note = @zstd.skippable_frame(3, b"made by me")
  let frame = @zstd.compress(b"hello, hello, hello")
  let stream = Bytes::from_array([..note[:], ..frame[:]])
  assert_eq(@zstd.frame_size(stream), 18)
  let rest = stream[18:]
  guard @zstd.inspect_frame(rest) is Zstd(info) else { fail("not a frame") }
  assert_eq(info.content_size, Some(19))
  assert_eq(@zstd.read_skippable_frame(stream).1, b"made by me")
  assert_eq(@zstd.decompress(stream), b"hello, hello, hello")
}
```

## Errors

A malformed stream raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError(kind, message)`. The decoder never aborts on bad input.

| Kind | When |
| --- | --- |
| `Truncated` | The input ends inside a frame. |
| `Corrupt` | The input is not a valid stream. |
| `TrailingData` | Bytes after the last frame start no frame. |
| `ChecksumMismatch` | The content checksum does not match. The encoder also raises it when the input does not match the `content_size` it was given. |
| `LimitExceeded` | A window over `max_window_bits` (`resource: Memory`), or more than `max_output` from `decompress` (`resource: Output`). |
| `DictionaryRequired(Some(id))` | The frame names a dictionary and none was given. |
| `DictionaryMismatch` | The frame names a different dictionary from the one given. |

A step that raises first hands out the output that comes before the error, so
a streaming caller may already hold bytes when the checksum at the end fails.
**Errors stick:** every later step raises the same kind until `reset()`.

In a `catch`, `CodecError(kind, _)` and the kinds match unqualified. To name
the types elsewhere, import `gaato/codec_bytes`, which re-exports them.

## Not included

Long-distance matching, multithreaded compression and dictionary training.

## Links

- [Comparison with other MoonBit implementations](https://github.com/gaato/codecs.mbt/blob/main/bench/README.md#compression-codecs-against-other-implementations):
  features, conformance results and speed
- [Compression levels and strategies](https://github.com/gaato/codecs.mbt/blob/main/zstd/docs/compression.md):
  how each level searches, and sizes against the reference `zstd`
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/zstd/RESOURCE_BOUNDS.md),
  [proofs](https://github.com/gaato/codecs.mbt/blob/main/zstd/PROOFS.md) and
  [test coverage](https://github.com/gaato/codecs.mbt/blob/main/zstd/TEST_COVERAGE.md)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md)
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/zstd/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0. The test frames under `testdata/upstream` come from
[facebook/zstd](https://github.com/facebook/zstd) under its BSD license; see
`NOTICE`.
