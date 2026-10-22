# Changelog

All notable changes to `gaato/deflate` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

### Changed

- gzip's CRC-32 is computed eight bytes at a time (slice-by-8), from 9 KiB of tables computed at start-up and shared by every decoder and encoder, in place of 1 KiB. The output and the errors are unchanged.
- **The README is about using the module.** Install, Usage, Packages, gzip, zlib, Streams that do not end, Limits, Errors and Links; links are absolute, so they work on mooncakes.io. The compression ratio table and how the levels follow libdeflate's moved to `docs/compression.md`, the exact memory figures are in RESOURCE_BOUNDS.md, and the checks against zlib and libdeflate in TEST_COVERAGE.md. The `gaato/codec_bytes` trait methods and `Header`'s derived methods have doc comments, and the repository-only `scripts/` and `docs/` are no longer packaged.

### Fixed

- **mooncakes.io shows the README once.** The README was both the module README and the root package's `README.mbt.md`, so the module page showed it twice; it is now `src/overview.mbt.md`, with `README.md` linked to it and named in `moon.mod`.

## [0.1.0] - 2026-10-22

### Added

- `gaato/deflate`: a streaming raw DEFLATE (RFC 1951) `Decoder`, with an optional preset dictionary, and `decompress`.
- `gaato/deflate/zlib`: a streaming zlib (RFC 1950) `Decoder`, with an optional preset dictionary (`DictionaryRequired(Some(id))` without it, `DictionaryMismatch` with another), `dictionary_id` for the id a stream names a dictionary by, `decompress`, and `is_header` to tell a zlib header from raw DEFLATE.
- `gaato/deflate/gzip`: a streaming gzip (RFC 1952) `Decoder` that reads every member by default, `header()` for the current member's `Header`, `max_header_bytes` for the extra field, name and comment, `keep_header=false` to skip them whatever their size (the header CRC is still checked), and `decompress`, which skips them.
- Each `Decoder` implements `gaato/codec_bytes`'s `Decode` (0.1.1) and raises `gaato/codec`'s `CodecError`; `until=EndOfMember` stops right after the first stream or member and consumes nothing past it. A step that raises first hands out the output before the error and reports what it consumed and wrote, and on `TrailingData` `last_consumed()` stops at the end of the stream. Malformed DEFLATE data is refused as zlib refuses it, with zlib's kind of error.
- A preset dictionary is held by reference, as a view of its last 32 KiB: `memory_usage()` is 46,592 bytes with a dictionary or without (the window, the tables and what builds them).
- `gaato/deflate`: a streaming raw DEFLATE `Encoder`, with levels 0 to 9 (6 by default, clamped) and an optional preset dictionary, and `compress`.
- `gaato/deflate/zlib`: a streaming zlib `Encoder` that writes zlib's header bytes (FLEVEL from the level, FDICT and DICTID with a dictionary) and the Adler-32, and `compress`.
- `gaato/deflate/gzip`: a streaming gzip `Encoder` that writes one member, with a default header of MTIME 0, OS 255 and zlib's XFL, or a given `Header` as it is; `Header::is_writable` says whether it can be (an unwritable one aborts); and `compress`.
- Each `Encoder` implements `gaato/codec_bytes`'s `Encode` and never raises; `Flush` is a sync flush (`00 00 ff ff`). The levels are libdeflate's, with its block splitting, in blocks of at most 64 KiB. Its output does not depend on how the input and the output are split, and is the same on every target. `memory_usage()` is fixed by the level, 542,516 bytes at the default one, with a dictionary or without, and for gzip the header's bytes.
