# Changelog

All notable changes to `gaato/deflate` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.0] - 2026-10-21

### Added

- `gaato/deflate`: a streaming raw DEFLATE (RFC 1951) `Decoder`, with an optional preset dictionary, and `decompress`.
- `gaato/deflate/zlib`: a streaming zlib (RFC 1950) `Decoder`, with an optional preset dictionary (`DictionaryRequired(Some(id))` without it, `DictionaryMismatch` with another), `dictionary_id` for the id a stream names a dictionary by, `decompress`, and `is_header` to tell a zlib header from raw DEFLATE.
- `gaato/deflate/gzip`: a streaming gzip (RFC 1952) `Decoder` that reads every member by default, `header()` for the current member's `Header`, `max_header_bytes` for the extra field, name and comment, `keep_header=false` to skip them whatever their size (the header CRC is still checked), and `decompress`, which skips them.
- Each `Decoder` implements `gaato/codec_bytes`'s `Decode` (0.1.1) and raises `gaato/codec`'s `CodecError`; `until=EndOfMember` stops right after the first stream or member and consumes nothing past it. A step that raises reports what it consumed and wrote before the error, and on `TrailingData` `last_consumed()` stops at the end of the stream, except for a `Corrupt` that moonbit-community/flate's inflater finds inside the DEFLATE data, whose step reports nothing (README, known limits).
- A preset dictionary is held by reference, as a view of its last 32 KiB: `memory_usage()` is 74,240 bytes with a dictionary or without.
- `gaato/deflate`: a streaming raw DEFLATE `Encoder`, with levels 0 to 9 (6 by default, clamped) and an optional preset dictionary, and `compress`.
- `gaato/deflate/zlib`: a streaming zlib `Encoder` that writes zlib's header bytes (FLEVEL from the level, FDICT and DICTID with a dictionary) and the Adler-32, and `compress`.
- `gaato/deflate/gzip`: a streaming gzip `Encoder` that writes one member, with a default header of MTIME 0, OS 255 and zlib's XFL, or a given `Header` as it is; `Header::is_writable` says whether it can be (an unwritable one aborts); and `compress`.
- Each `Encoder` implements `gaato/codec_bytes`'s `Encode` and never raises; `Flush` is a sync flush (`00 00 ff ff`). Its output does not depend on how the input and the output are split, and is the same on every target. The encoding is moonbit-community/flate's deflater, which no public signature names: `memory_usage()` is 689,394 bytes, with a dictionary or without, and for gzip the header's bytes.
