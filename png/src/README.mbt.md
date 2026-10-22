# gaato/png

A streaming PNG decoder for MoonBit, part of
[codecs.mbt](https://github.com/gaato/codecs.mbt). It is being written and
has no public API yet.

The decoder will implement the image contract of
[`gaato/codec_image`](https://mooncakes.io/docs/gaato/codec_image): input in
chunks of any size, whole rows written into output slices the caller
provides, and memory bounded by limits the caller sets, with the image data
inflated by the zlib decoder of
[`gaato/deflate`](https://mooncakes.io/docs/gaato/deflate). The rules it
keeps are in the repository's CONTRACT.md, in its part on images.
