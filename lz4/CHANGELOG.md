# Changelog

All notable changes to `gaato/lz4` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.1] - 2026-11-21

### Changed

- **Faster one-shot calls**, and faster encoding and decoding on JS, with the same bytes out: `compress`, `decompress` and `decompress_block` write straight into one growing array instead of appending 64 KiB pieces to a buffer, and the window and the encoder's input move without core's checked copy on JS. Decoding the benchmarks' 512 KiB text whole took 11.5 ms on JS, now 4.0.
- **Faster, mostly in small pieces**, with the same bytes out: short sequences copy 16 bytes at once on Native and Wasm, XXH32 makes no calls (but on JS), the encoder hashes each block from its own buffer (but on JS), and the frame's 64-bit total grows once per block, only in frames that declare their size. The benchmarks' text, its first 64 KiB handed over 1 byte at a time, took 2.37 ms to compress on Native, now 1.36 (Wasm 4.70 → 1.99, Wasm GC 2.86 → 2.04); 16 bytes at a time, 1.60 ms to decode on JS, now 1.24.
- **The README is rewritten**: complete examples of whole-buffer and streaming use, the defaults and limits, and the errors; a streaming loop now passes `end=true` (or `Finish`) once even for an empty source.

### Fixed

- **The README's errors list `Unsupported` for a legacy frame under `until=EndOfMember`**, and say that errors stick until `reset`.

## [0.1.0] - 2026-11-16

### Added

- **LZ4 frames, streamed**: `Decoder` and `Encoder` under the rules of `gaato/codec_bytes`. The decoder reads independent and linked blocks of 64 KiB to 4 MiB, stored or compressed, checks the header, block and content checksums (XXH32) and the content size, skips skippable frames, reads legacy frames (`lz4 -l`) and frames one after another, and stops after the first under `until=EndOfMember` (a legacy frame raises `Unsupported` there); `frame_info()` gives the header. It holds a window of 256 KiB at most, never a whole block. A block's bytes come out before the checksums that cover them, as provisional output.
- **The encoder is lz4's fast one**: with the same options and no dictionary, its frames and blocks are the bytes lz4 1.10.0 writes, at every `acceleration`, as the tests hold it to; with a dictionary, which it indexes whole, its output differs from lz4's, within 0.1 % of its size on the test data. Options: `block_size`, `linked`, `checksum`, `block_checksum`, `content_size` (held to, and written unless 0, as lz4 writes it) and `dictionary` with `dictionary_id`.
- **Dictionaries** for frames (`lz4 -D`) and blocks: `Decoder(dictionary=…)`, `decompress(dictionary=…)`, `compress_block(dictionary=…)`, `decompress_block(dictionary=…)`; a frame that names one raises `DictionaryRequired` without it.
- **Blocks on their own**: `compress_block` and `decompress_block` (lz4's `LZ4_compress_fast` and `LZ4_decompress_safe`), `block_compress_bound`.
- `compress`, `decompress`, `skippable_frame`, `compress_bound`, `decoder_memory_bound` and `encoder_memory_bound`.
