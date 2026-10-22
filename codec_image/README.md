# gaato/codec_image

The contract of streaming image decoders in
[codecs.mbt](https://github.com/gaato/codecs.mbt): a decoder is driven step
by step, takes input in chunks of any size, writes whole rows into output
slices the caller provides, and keeps its memory within the limits it was
given. A step stops to report the image's header, the start and the end of
each frame, the rows it wrote, and metadata it was asked for. Code written
against `Decode` works with every image decoder that implements it, such as
[`gaato/png`](https://mooncakes.io/docs/gaato/png).

Rows come out in the format's own layout (for PNG, packed samples, palette
indices, 16-bit samples big-endian), and interlaced images pass by pass:
where each row and each pixel of a pass lies in the frame is read from the
decoder. Converting pixels, applying palettes, and assembling passes and
frames into a picture are left to functions outside the decoders, which each
format module provides for its own layout.

Errors are [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError`. This package re-exports it with `ErrorKind`, `Limit` and
`Resource`, so it is the only import a consumer needs to name them. In a
`catch` on a decoder's step, `CodecError(kind, message)` and the kinds match
unqualified; elsewhere, qualify a constructor by its type, as in
`@codec_image.CodecError::CodecError(kind, _)`. The rules every decoder
keeps are in the repository's CONTRACT.md, in its part on images.
