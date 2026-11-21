# gaato/codec_bytes

Write a compression loop once and use it with every byte-stream format in
[codecs.mbt](https://github.com/gaato/codecs.mbt): Zstandard, Brotli, gzip,
zlib, raw DEFLATE, LZ4, Snappy and LZW. The `Decode` and `Encode` traits drive
a codec step by step. You choose the size of every input chunk and output
buffer, and the codec's memory stays within the limits it was built with. An
HTTP client or server can support `gzip`, `br` and `zstd` with one read loop
and one write loop.

This package defines the traits only. The codecs come from the format modules,
such as [`gaato/zstd`](https://mooncakes.io/docs/gaato/zstd),
[`gaato/brotli`](https://mooncakes.io/docs/gaato/brotli) and
[`gaato/deflate`](https://mooncakes.io/docs/gaato/deflate). Each format's
`Decoder` and `Encoder` implement these traits.

## Install

```sh
moon add gaato/codec_bytes
```

## Decode with any format

Each step consumes a prefix of the input and writes a prefix of the output
slice. `last_consumed()` and `last_produced()` say how much, and the `Status`
says why it stopped. Pass `end=true` once the source has run dry, with an empty
input if need be, so that a stream cut short, or a source with nothing in it,
raises `Truncated` instead of ending quietly.

```mbt check
///|
/// Decodes what `read` hands over, `None` once it has no more, with any
/// decoder, passing each piece of output to `write`.
fn[D : @codec_bytes.Decode] decode_all(
  decoder : D,
  read : () -> Bytes?,
  write : (Bytes) -> Unit,
) -> Unit raise {
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
```

`@zstd.Decoder()`, `@brotli.Decoder()` and `@gzip.Decoder()` all go in
unchanged. To show the contract on its own, here is the smallest decoder that
keeps it, one that copies its input:

```mbt check
///|
/// A decoder of the identity format: output is input.
struct Identity {
  mut taken : Int32
  mut written : Int32
}

///|
impl @codec_bytes.Decode for Identity with fn step(self, input, output, end~) {
  let n = input.length().min(output.length())
  for i in 0..<n {
    output[i] = input[i]
  }
  self.taken = n
  self.written = n
  if n < input.length() {
    NeedMoreOutput
  } else if end {
    Done
  } else {
    NeedMoreInput
  }
}

///|
impl @codec_bytes.Decode for Identity with fn last_consumed(self) {
  self.taken
}

///|
impl @codec_bytes.Decode for Identity with fn last_produced(self) {
  self.written
}

///|
impl @codec_bytes.Decode for Identity with fn reset(self) {
  self.taken = 0
  self.written = 0
}

///|
impl @codec_bytes.Decode for Identity with fn memory_usage(_self) {
  0
}

///|
test "drive a decoder through the contract" {
  let decoder : Identity = { taken: 0, written: 0, }
  let decoded = Buffer()
  decode_all(decoder, pieces_of([b"hel", b"lo"]), bytes => {
    decoded.write_bytes(bytes)
  })
  assert_eq(decoded.to_bytes(), b"hello")
}
```

**The loop bounds memory, not output.** A decoder's memory stays within its
limits however much it writes, but nothing in the streaming API caps the total
it writes. A few kilobytes of input can expand to gigabytes. When the input
comes from elsewhere, count the bytes your sink receives and stop when they
pass your budget. The one-shot `decompress` functions do this for you with
`max_output`.

## Encode with any format

An encoder takes an `EncodeAction` instead of `end`:

| Action | Use it for |
| --- | --- |
| `Continue` | Ordinary input. The encoder writes output when it has enough to write. |
| `Flush` | Making everything so far decodable while the stream stays open, for example to send one part of an HTTP response now. LZW and `.Z` cannot flush and raise `Unsupported`. |
| `Finish` | The last input. Keep calling until the step returns `Done`, so that the trailer is written. |

```mbt check
///|
/// Compresses what `read` hands over, `None` once it has no more, with any
/// encoder, passing each piece of output to `write`. An empty source still
/// finishes the stream, so its trailer is written.
pub fn[E : @codec_bytes.Encode] encode_all(
  encoder : E,
  read : () -> Bytes?,
  write : (Bytes) -> Unit,
) -> Unit raise {
  let out = FixedArray::make(64 * 1024, b'\x00')
  for ;; {
    let piece = read()
    let action : @codec_bytes.EncodeAction = if piece is None {
      Finish
    } else {
      Continue
    }
    let mut input = piece.unwrap_or(b"")[:]
    for ;; {
      let status = encoder.step(input, out.mut_view(), action~)
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
```

## Errors

A step raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError(kind, message)`. This package re-exports it together with
`ErrorKind`, `Limit` and `Resource`, so no other import is needed to name them.
In a `catch` around a step, `CodecError(kind, message)` and the kinds match
unqualified. Elsewhere, qualify the constructor, as in
`@codec_bytes.CodecError::CodecError(kind, _)`.

- **Output before the error is written first.** `last_consumed()` and
  `last_produced()` count what the failing step took and wrote. A decoder may
  already have handed out bytes when a checksum at the end fails. If your
  consumer needs all or nothing, hold the output until `Done`.
- **Errors stick.** After a step raises, every later step raises the same kind
  and consumes nothing, until `reset()`. To reuse a decoder for the next stream,
  call `reset()`. It then behaves exactly like a new one.

## Streams that never end

Some protocols compress a whole connection as one stream and flush after each
message. Discord's gateway (`zlib-stream`, `zstd-stream`) is one. Keep one decoder for the
connection, pass every piece with `end=false`, and treat `NeedMoreInput` as
"everything this input determines is out". The
[contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md#streams-that-do-not-end)
describes this case.

## Links

- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md):
  every rule a codec keeps, and what each format does with `EndOfMember`, `Flush`
  and trailing data
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/codec_bytes/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0.
