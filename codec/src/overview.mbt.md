# gaato/codec

One error type for every decoder and encoder in
[codecs.mbt](https://github.com/gaato/codecs.mbt), from Zstandard and gzip to
PNG. A program that accepts several formats, such as an HTTP server taking
compressed request bodies, can answer a cut stream, a body that grows past its
budget or a missing dictionary the same way whichever format failed.

This module only defines types. You rarely add it yourself: every codec
depends on it, and [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes)
and [`gaato/codec_image`](https://mooncakes.io/docs/gaato/codec_image)
re-export its types, so code that already imports one of those can name
`CodecError` through it. Add it directly when a package handles codec errors
without importing either.

## Install

```sh
moon add gaato/codec
```

## Turn a codec error into a reply

A `CodecError` carries a kind to act on and a message for people. Match on the
kind, not the message, and keep a wildcard arm: `ErrorKind` and `Resource` may
gain cases.

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

| Kind | Meaning |
| --- | --- |
| `Truncated` | The input ended inside a stream. |
| `Corrupt` | The input is not a valid stream. |
| `ChecksumMismatch` | A checksum, or a length the stream declares, does not match the data. |
| `TrailingData` | Bytes follow the end of the stream. |
| `LimitExceeded(limit)` | Going on would pass a limit. `limit` names the resource (`Memory` or `Output`), the bytes allowed, and the bytes needed when the codec knows them. |
| `DictionaryRequired(id)` | The stream needs a dictionary that was not given. |
| `DictionaryMismatch` | The stream needs a different dictionary from the one given. |
| `Unsupported` | The stream is valid but uses a feature the codec does not implement. |

Each codec's README says which kinds it raises and when. A codec that has
raised keeps raising the same kind until it is `reset`.

## Links

- [The codec contracts](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md):
  the rules every byte-stream and image codec keeps
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/codec/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0.
