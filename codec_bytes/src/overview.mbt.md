# gaato/codec_bytes

The contract of streaming byte-stream codecs in
[codecs.mbt](https://github.com/gaato/codecs.mbt): a decoder or an encoder is
driven step by step, takes input in chunks of any size, writes into output
slices of any size, and keeps its memory within the limits it was given.
Code written against `Decode` and `Encode` works with every codec that
implements them, such as [`gaato/zstd`](https://mooncakes.io/docs/gaato/zstd),
[`gaato/brotli`](https://mooncakes.io/docs/gaato/brotli) and
[`gaato/deflate`](https://mooncakes.io/docs/gaato/deflate).

## Install

```sh
moon add gaato/codec_bytes
```

## Usage

Write the loop that drives a decoder once, against `Decode`. Each step
consumes a prefix of the input and writes a prefix of the output slice;
`last_consumed()` and `last_produced()` say how much, and the `Status` says
why it stopped. Pass `end=true` with the last input, so that a stream cut
short raises `Truncated` instead of ending quietly.

```mbt check
///|
/// Decodes `chunks` with any decoder, handing each slice of output to `sink`.
fn[D : @codec_bytes.Decode] decode_all(
  decoder : D,
  chunks : Array[Bytes],
  sink : (BytesView) -> Unit,
) -> Unit raise {
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
```

Any codec's `Decoder` goes in, `@zstd.Decoder()` or `@gzip.Decoder()` alike.
To show the contract on its own, here is the smallest decoder that keeps it,
one that copies its input:

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
  decode_all(decoder, [b"hel", b"lo"], bytes => {
    decoded.write_bytes(bytes.to_owned())
  })
  assert_eq(decoded.to_bytes(), b"hello")
}
```

Encoders work the same way through `Encode`, with an `EncodeAction` in place
of `end`: `Continue` takes input, `Flush` makes the output so far decode to
the input so far, and `Finish` ends the stream.

## Errors

A step raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError(kind, message)`. This package re-exports it with `ErrorKind`,
`Limit` and `Resource`, so it is the only import a consumer needs to name
them. In a `catch` on a step, `CodecError(kind, message)` and the kinds match
unqualified; elsewhere, qualify a constructor by its type, as in
`@codec_bytes.CodecError::CodecError(kind, _)`.

A step that raises first writes the output that comes before the error, and
`last_taken()` and `last_written()` count what it took and wrote. Errors
stick: later steps raise the same kind until `reset`.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/codec_bytes/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md): every rule a codec keeps, streams that never end among them

## License

Apache-2.0.
