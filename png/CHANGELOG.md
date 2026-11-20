# Changelog

All notable changes to `gaato/png` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

### Changed

- **Faster decoding in small pieces**: the decoder no longer calls its zlib decoder again once that has used all of an IDAT chunk's bytes and asked for more. A file handed over 1 byte at a time decodes in 30 % less time on Native and JS, and 35 to 37 % less on Wasm and Wasm GC.
- **The README links to the PNG decoder comparison** in bench/README.md
  instead of quoting time ratios against another decoder, which change with
  that decoder's version.

## [0.1.3] - 2026-11-15

### Added

- **Text and time chunks read into values.** `parse_text(chunk_type, block)` reads the block of a reported tEXt, zTXt or iTXt into a `Text` (keyword, language tag, translated keyword and text, from Latin-1 or UTF-8), and `parse_time(block)` a tIME into a `Time`; both raise `Corrupt` for what the specification does not allow. On PngSuite they read every text and tIME chunk as Python does.

### Fixed

- **`last_produced` says it counts the block a `Metadata` step writes;** it said zero after every answer but `Rows`.

## [0.1.2] - 2026-11-15

### Changed

- **Decoding is faster, most on native and Wasm.** There, the Sub, Average and Paeth filters of 8-bit RGB and RGBA rows are reversed a pixel at a time with SIMD; on the other targets, and for other pixel sizes, a pixel lane at a time, Paeth without waiting for the byte to its left. The CRC-32 reads its tables and input without index checks. The benchmark image (512 × 384 RGB) decodes in 1.81 ms in place of 2.03 ms on native, 2.22 in place of 2.98 ms on Wasm and 5.24 in place of 6.04 ms on JS, and about as fast as before on Wasm GC; interlaced, in 2.14 in place of 3.23 ms on native, 2.63 in place of 5.39 ms on Wasm, 4.93 in place of 5.65 ms on Wasm GC and 6.15 in place of 6.55 ms on JS. `moon prove` still checks that the filters, the SIMD loops among them, read and write only inside their rows.
- `Converter::rgba8` converts 8-bit rows with a loop for each color type. The output and the errors are unchanged.

## [0.1.1] - 2026-11-14

### Changed

- The decoder reverses the Up filter sixteen bytes at a time with SIMD on native and Wasm (core's `@v128`, experimental): the 226 Up rows of a 512 × 384 RGB image take 18 µs in place of 175 µs on native and 26 µs in place of 271 µs on Wasm. With `gaato/deflate`'s faster Adler-32, that image decodes in 1.89 ms in place of 2.34 ms on native and 2.88 ms in place of 3.62 ms on Wasm. `moon prove` checks that its sixteen-byte loads and stores stay within the rows. JS and Wasm GC, where SIMD does not pay, are unchanged, as are the output and the errors.

## [0.1.0] - 2026-10-23

### Added

- A streaming `Decoder` that implements `gaato/codec_image`'s `Decode`: every color type and bit depth, Adam7 pass by pass, rows in PNG's own layout. `step_into` writes into a whole `FixedArray` with bulk copies. `bit_depth()`, `color_type()`, `interlaced()`, `palette()` and `ignored_chunks()` for what the image says. `max_row_bytes` (8,000,000 by default) bounds a row; the decoder holds two rows and a zlib decoder, 47,360 + 2 × (1 + row bytes) bytes.
- Errors as libpng's defaults make them: a critical chunk's CRC and the Adler-32 are checked (`ChecksumMismatch`), an unknown critical chunk is `Unsupported`, ancillary chunks out of place, repeated or with a wrong CRC are left out and counted, and data after the zlib stream is dropped.
- The ancillary chunks of the third edition. tRNS, sBIT, gAMA, cHRM, sRGB, cICP, mDCV, cLLI, pHYs and bKGD are read into `transparency()`, `significant_bits()`, `gamma()`, `chromaticities()`, `srgb_intent()`, `coding_points()`, `mastering_display()`, `light_level()`, `physical_size()` and `background()`, and left out when their values are not allowed. The structs they return are read-only: only the decoder makes them, so fields can be added without breaking callers. `report` names the ancillary types to hand out as `Metadata` blocks once their CRC has passed (`metadata_type()` says which), iCCP, zTXt and iTXt inflated; `max_chunk_bytes` (1 MiB by default) bounds a block.
- APNG: each frame a `Frame` with its rows, placed by `frame_x()` to `frame_height()`, shown as `delay_numerator()`, `delay_denominator()`, `dispose()` and `blend()` say; `animated()`, `frame_count()`, `plays()` and `in_animation()` for what acTL and fcTL say. Sequence numbers, rectangles and the count of frames are checked. `animation=false` reads the default image only.
- `decode`, a whole image deinterlaced in PNG's layout, returned once every check has passed, its bytes bounded from IHDR by `max_output`, 512 MiB by default; `is_signature`. `Converter` (from `Decoder::converter`, `Image::converter` or its constructor) turns rows into 8-bit or 16-bit RGBA or the png crate's EXPAND shape, an index past the palette as opaque black. `scatter` and the `adam7_*` functions place a pass's rows in an image.
- Proofs (`moon prove`, PROOFS.md): the Paeth predictor, Adam7's pass sizes, a row's bytes against `max_row_bytes`, an fcTL's rectangle, a chunk type's letters and property bit, and the conversions' sample arithmetic match the specification; the reversal of the filters reads and writes only inside its rows.
