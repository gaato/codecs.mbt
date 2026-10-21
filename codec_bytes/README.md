# gaato/codec_bytes

The contract of streaming byte-stream codecs in
[codecs.mbt](https://github.com/gaato/codecs.mbt): a decoder or an encoder is
driven step by step, takes input in chunks of any size, writes into output
slices of any size, and keeps its memory within the limits it was given.
Code written against `Decode` and `Encode` works with every codec that
implements them, such as [`gaato/zstd`](https://mooncakes.io/docs/gaato/zstd)
and [`gaato/brotli`](https://mooncakes.io/docs/gaato/brotli).

Errors are [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError`. This package re-exports it with `ErrorKind`, `Limit` and
`Resource`, so it is the only import a consumer needs to name them. In a
`catch` on a codec's step, `CodecError(kind, message)` and the kinds match
unqualified; elsewhere, qualify a constructor by its type, as in
`@codec_bytes.CodecError::CodecError(kind, _)`. The rules every codec keeps,
streams that never end among them, are in the repository's CONTRACT.md.
