# Changelog

All notable changes to `gaato/snappy` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

### Added

- **Snappy's raw format, whole**: `compress_raw` and `decompress_raw`, which checks the declared length against `max_output` and against what the stream's bytes can make before allocating, and `raw_compress_bound`.
- **Snappy's framing format, streamed**: `Decoder` and `Encoder` under the rules of `gaato/codec_bytes`, with each chunk's CRC-32C checked (`verify_checksums=false` skips it), skippable chunks and padding, streams one after another, and `until=EndOfMember` to stop at the next stream; `compress`, `decompress` and `compress_bound`. The encoder is snappy 1.1's, and its raw and framed output are the snap crate's to the byte on the test data, but that it writes the identifier for no input, where the snap crate writes nothing. A chunk that fails its CRC-32C gives its bytes, then `ChecksumMismatch`, as the contract has provisional output; a compressed chunk longer than 76,494 bytes, which the format allows and no encoder writes, raises `LimitExceeded`.
- `decoder_memory_bound` and `encoder_memory_bound`, the most the framing decoder and encoder hold.
