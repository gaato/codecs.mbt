# Changelog

All notable changes to `gaato/lzw` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

### Changed

- **Faster one-shot calls**, with the same bytes out: `compress` and `decompress` write straight into one growing array instead of appending 64 KiB pieces to a buffer. Decoding the benchmarks' 512 KiB text whole took 8.8 ms on JS, now 4.1.

## [0.1.0] - 2026-11-16

### Added

- **LZW in four flavours**, chosen by `Format`: `gif(min_code_size)`, `tiff()`, `pdf(early_change~)` and `unix_compress(max_bits~, block_mode~)` (.Z), each with its bit order, clear and end codes, widths and point of widening. `gif` and `unix_compress` raise `Unsupported` for sizes their formats do not have, .Z of 9 bits among them (no writer and reader agree on it).
- **`Decoder` and `Encoder`** under the rules of `gaato/codec_bytes`: input and output in pieces of any size; GIF tables that fill without a clear; `allow_missing_end` for streams without their end code; `until=EndOfMember` stopping after the end code (.Z, which has none, raises `Unsupported`); `Flush` raises `Unsupported`, as LZW cannot flush. The .Z decoder takes the header's width and block mode (`stream_format()`) and refuses a width over its own with `LimitExceeded`.
- The encoder writes compress's .Z bytes on the test data, its ratio check included, and weezl's GIF and TIFF bytes until the table fills, clearing it where giflib and libtiff do. weezl, compress and `gzip -d` decode every stream it writes.
- `compress`, `decompress`, `compress_bound`, `decoder_memory_bound` and `encoder_memory_bound`.
