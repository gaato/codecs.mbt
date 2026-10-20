# gaato/codec_bytes

The contract of streaming byte-stream codecs in
[codecs.mbt](https://github.com/gaato/codecs.mbt): a decoder or an encoder is
driven step by step, takes input in chunks of any size, writes into output
slices of any size, and keeps its memory within the limits it was given.
Code written against `Decode` and `Encode` works with every codec that
implements them, such as [`gaato/zstd`](https://mooncakes.io/docs/gaato/zstd)
and [`gaato/brotli`](https://mooncakes.io/docs/gaato/brotli).

Errors are `gaato/codec`'s `CodecError`. The rules every codec keeps are in
the repository's CONTRACT.md.
