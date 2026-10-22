# gaato/codec

The error kinds and limits shared by the streaming codecs of
[codecs.mbt](https://github.com/gaato/codecs.mbt). A codec of any kind, a
byte-stream decoder or an image decoder, raises `CodecError` with one of
these kinds through its kind's contract, so that callers handle failures the
same way whatever they decode.

This module only defines types. A codec such as
[`gaato/zstd`](https://mooncakes.io/docs/gaato/zstd) brings it in, and
[`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes)
re-exports its types, so a consumer of byte-stream codecs can name them with
that one import instead.

## Install

```sh
moon add gaato/codec
```

## Usage

A `CodecError` carries a kind to act on and a message for people. Match on
the kind, and keep a wildcard arm: `ErrorKind` and `Resource` may gain cases.

```mbt check
///|
/// What to tell the client that sent a compressed request body.
fn describe(error : @codec.CodecError) -> String {
  match error.kind() {
    LimitExceeded({ resource: Output, limit, .. }) =>
      "the body is over \{limit} bytes once decompressed"
    LimitExceeded(_) => "the body needs too much memory to decompress"
    Truncated => "the body ends too early"
    DictionaryRequired(_) | DictionaryMismatch =>
      "the body needs a dictionary this server does not have"
    _ => "the body is not valid"
  }
}

///|
test "describe codec errors" {
  let too_big = @codec.CodecError::CodecError(
    LimitExceeded({ resource: Output, needed: None, limit: 1024, }),
    "more than max_output bytes",
  )
  assert_eq(describe(too_big), "the body is over 1024 bytes once decompressed")
  assert_eq(
    describe(@codec.CodecError::CodecError(Truncated, "end of input")),
    "the body ends too early",
  )
}
```

## Error kinds

- `Truncated`: the input ended inside a stream.
- `Corrupt`: the input is not a valid stream.
- `ChecksumMismatch`: a checksum, or a length the stream declares, does not
  match the data.
- `TrailingData`: bytes follow the end of the stream.
- `LimitExceeded(limit)`: going on would exceed a limit. `limit` says which
  resource (`Memory` or `Output`), how much the stream needs when that is
  known, and how much is allowed, in bytes.
- `DictionaryRequired(id)` and `DictionaryMismatch`: the stream needs a
  dictionary that was not given, or was given another one.
- `Unsupported`: the stream is valid but uses something the codec does not
  implement.

Each codec's README says which kinds it raises and when.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/codec/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md)

## License

Apache-2.0.
