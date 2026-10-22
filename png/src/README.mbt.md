# gaato/png

A streaming PNG decoder for MoonBit, part of
[codecs.mbt](https://github.com/gaato/codecs.mbt). It is being written: the
decoder reads every color type and bit depth, interlaced or not, and skips
ancillary chunks; reading them, APNG, and functions that convert rows to
RGBA are still to come.

`Decoder` implements the image contract of
[`gaato/codec_image`](https://mooncakes.io/docs/gaato/codec_image): input in
chunks of any size, whole rows written into output slices the caller
provides, and memory bounded by limits the caller sets: two rows and the
zlib decoder of [`gaato/deflate`](https://mooncakes.io/docs/gaato/deflate),
whatever the image's height. Rows come out in PNG's own layout (packed
samples, palette indices, 16-bit samples big-endian, without the filter
type byte), and an interlaced image pass by pass. The rules it keeps are in
the repository's CONTRACT.md, in its part on images.
