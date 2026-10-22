# Changelog

All notable changes to `gaato/png` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.0] - 2026-10-22

### Added

- A streaming `Decoder` that implements `gaato/codec_image`'s `Decode`: every color type and bit depth, Adam7 pass by pass, rows in PNG's own layout. `bit_depth()`, `color_type()`, `interlaced()`, `palette()` and `ignored_chunks()` for what the image says. `max_row_bytes` (8,000,000 by default) bounds a row; the decoder holds two rows and a zlib decoder, 47,360 + 2 × (1 + row bytes) bytes.
- Errors as libpng's defaults make them: a critical chunk's CRC and the Adler-32 are checked (`ChecksumMismatch`), an unknown critical chunk is `Unsupported`, ancillary chunks out of place, repeated or with a wrong CRC are left out and counted, and data after the zlib stream is dropped.
