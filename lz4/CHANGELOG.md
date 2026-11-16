# Changelog

All notable changes to `gaato/lz4` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.0] - 2026-11-16

### Added

- **LZ4 frames, streamed**: `Decoder` and `Encoder` under the rules of `gaato/codec_bytes`. The decoder reads independent and linked blocks of 64 KiB to 4 MiB, stored or compressed, checks the header, block and content checksums (XXH32) and the content size, skips skippable frames, reads legacy frames (`lz4 -l`) and frames one after another, and stops after the first under `until=EndOfMember` (a legacy frame raises `Unsupported` there); `frame_info()` gives the header. It holds a window of 256 KiB at most, never a whole block. A block's bytes come out before the checksums that cover them, as provisional output.
- **The encoder is lz4's fast one**: with the same options and no dictionary, its frames and blocks are the bytes lz4 1.10.0 writes, at every `acceleration`, as the tests hold it to; with a dictionary, which it indexes whole, its output differs from lz4's, within 0.1 % of its size on the test data. Options: `block_size`, `linked`, `checksum`, `block_checksum`, `content_size` (held to, and written unless 0, as lz4 writes it) and `dictionary` with `dictionary_id`.
- **Dictionaries** for frames (`lz4 -D`) and blocks: `Decoder(dictionary=…)`, `decompress(dictionary=…)`, `compress_block(dictionary=…)`, `decompress_block(dictionary=…)`; a frame that names one raises `DictionaryRequired` without it.
- **Blocks on their own**: `compress_block` and `decompress_block` (lz4's `LZ4_compress_fast` and `LZ4_decompress_safe`), `block_compress_bound`.
- `compress`, `decompress`, `skippable_frame`, `compress_bound`, `decoder_memory_bound` and `encoder_memory_bound`.
