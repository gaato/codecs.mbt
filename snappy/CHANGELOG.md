# Changelog

All notable changes to `gaato/snappy` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.1] - 2026-11-21

### Changed

- **Faster one-shot `decompress`**, and faster encoding and decoding on JS, with the same bytes out: `decompress` writes straight into one growing array instead of appending pieces to a buffer, and literals, copies and chunks move without core's checked copy on JS. Decoding the benchmarks' 512 KiB text whole took 12.0 ms on JS, now 6.5.
- **Faster, mostly in small pieces**, with the same bytes out: elements are worked out in 32-bit arithmetic, short literals and copies move 16 bytes at once, the encoder reads its input and hash table without index checks, and a raw `decompress` returns its buffer without a last copy. The benchmarks' text, its first 64 KiB handed over 16 bytes at a time, took 208 µs to decode on Native, now 137 (Wasm 304 → 181, JS 750 → 492); 1 byte at a time, 1.65 ms to compress on Native, now 1.28 (Wasm 2.52 → 1.99).
- **The README is rewritten**: complete examples of whole-buffer and streaming use, the defaults and limits, and the errors; a streaming loop now passes `end=true` (or `Finish`) once even for an empty source.

### Fixed

- **The README's errors list `LimitExceeded` for a compressed chunk over 76,494 bytes**, with `resource: Memory`, and say that errors stick until `reset`.

## [0.1.0] - 2026-11-16

### Added

- **Snappy's raw format, whole**: `compress_raw` and `decompress_raw`, which checks the declared length against `max_output` and against what the stream's bytes can make before allocating, and `raw_compress_bound`.
- **Snappy's framing format, streamed**: `Decoder` and `Encoder` under the rules of `gaato/codec_bytes`, with each chunk's CRC-32C checked (`verify_checksums=false` skips it), skippable chunks and padding, streams one after another, and `until=EndOfMember` to stop at the next stream; `compress`, `decompress` and `compress_bound`. The encoder is snappy 1.1's, and its raw and framed output are the snap crate's to the byte on the test data, but that it writes the identifier for no input, where the snap crate writes nothing. A chunk that fails its CRC-32C gives its bytes, then `ChecksumMismatch`, as the contract has provisional output; a compressed chunk longer than 76,494 bytes, which the format allows and no encoder writes, raises `LimitExceeded`.
- `decoder_memory_bound` and `encoder_memory_bound`, the most the framing decoder and encoder hold.
