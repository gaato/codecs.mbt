# Changelog

All notable changes to `gaato/deflate` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.0] - 2026-10-21

### Added

- `gaato/deflate`: a streaming raw DEFLATE (RFC 1951) `Decoder`, with an optional preset dictionary, and `decompress`.
- `gaato/deflate/zlib`: a streaming zlib (RFC 1950) `Decoder`, with an optional preset dictionary (`DictionaryRequired(Some(id))` without it, `DictionaryMismatch` with another), `decompress`, and `is_header` to tell a zlib header from raw DEFLATE.
- `gaato/deflate/gzip`: a streaming gzip (RFC 1952) `Decoder` that reads every member by default, `header()` for the current member's `Header`, `max_header_bytes` for the extra field, name and comment, and `decompress`.
- Each `Decoder` implements `gaato/codec_bytes`'s `Decode` and raises `gaato/codec`'s `CodecError`; `until=EndOfMember` stops right after the first stream or member and consumes nothing past it.
