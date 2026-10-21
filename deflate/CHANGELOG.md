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
- `gaato/deflate/gzip`: a streaming gzip (RFC 1952) `Decoder` that reads every member by default, `header()` for the current member's `Header`, `max_header_bytes` for the extra field, name and comment, and `decompress`.
- Each `Decoder` implements `gaato/codec_bytes`'s `Decode` (0.1.1) and raises `gaato/codec`'s `CodecError`; `until=EndOfMember` stops right after the first stream or member and consumes nothing past it. A step that raises reports what it consumed and wrote before the error, and on `TrailingData` `last_consumed()` stops at the end of the stream, except for a `Corrupt` that moonbit-community/flate's inflater finds inside the DEFLATE data, whose step reports nothing (README, known limits).
- A preset dictionary is held by reference, as a view of its last 32 KiB: `memory_usage()` is 74,240 bytes with a dictionary or without.
