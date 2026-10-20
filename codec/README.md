# gaato/codec

The error kinds and limits shared by the streaming codecs of
[codecs.mbt](https://github.com/gaato/codecs.mbt). A codec of any kind, a
byte-stream decoder or an image decoder, raises `CodecError` with one of
these kinds through its kind's contract, so that callers handle failures the
same way whatever they decode.

This module only defines types. Byte-stream codecs implement
[`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes); see the
repository's CONTRACT.md for the rules they keep.
