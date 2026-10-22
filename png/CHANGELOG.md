# Changelog

All notable changes to `gaato/png` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.0] - 2026-10-22

### Added

- A streaming `Decoder` that implements `gaato/codec_image`'s `Decode`: every color type and bit depth, Adam7 pass by pass, rows in PNG's own layout. `step_into` writes into a whole `FixedArray` with bulk copies. `bit_depth()`, `color_type()`, `interlaced()`, `palette()` and `ignored_chunks()` for what the image says. `max_row_bytes` (8,000,000 by default) bounds a row; the decoder holds two rows and a zlib decoder, 47,360 + 2 × (1 + row bytes) bytes.
- Errors as libpng's defaults make them: a critical chunk's CRC and the Adler-32 are checked (`ChecksumMismatch`), an unknown critical chunk is `Unsupported`, ancillary chunks out of place, repeated or with a wrong CRC are left out and counted, and data after the zlib stream is dropped.
- The ancillary chunks of the third edition. tRNS, sBIT, gAMA, cHRM, sRGB, cICP, mDCV, cLLI, pHYs and bKGD are read into `transparency()`, `significant_bits()`, `gamma()`, `chromaticities()`, `srgb_intent()`, `coding_points()`, `mastering_display()`, `light_level()`, `physical_size()` and `background()`, and left out when their values are not allowed. The structs they return are read-only: only the decoder makes them, so fields can be added without breaking callers. `report` names the ancillary types to hand out as `Metadata` blocks once their CRC has passed (`metadata_type()` says which), iCCP, zTXt and iTXt inflated; `max_chunk_bytes` (1 MiB by default) bounds a block.
- APNG: each frame a `Frame` with its rows, placed by `frame_x()` to `frame_height()`, shown as `delay_numerator()`, `delay_denominator()`, `dispose()` and `blend()` say; `animated()`, `frame_count()`, `plays()` and `in_animation()` for what acTL and fcTL say. Sequence numbers, rectangles and the count of frames are checked. `animation=false` reads the default image only.
