# Changelog

All notable changes to `gaato/deflate` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

### Added

- **`gaato/deflate/deflate64`**, a decode-only package for ZIP method 9:
  `Decoder(until?)`, `decompress(input, max_output?)` and
  `decoder_memory_bound()`. It keeps a fixed 64 KiB window and 79,384 bytes
  of element payload. The ordinary DEFLATE decoder remains RFC 1951.
- **Levels 10 to 12** in the raw DEFLATE, zlib and gzip encoders: libdeflate
  1.24's near-optimal parsing, with binary-tree matches and iterative
  minimum-cost paths. Output is byte-identical to the reference with the
  documented streaming limits; levels 0 to 9 keep their existing bytes.
- **`decompress(input, dictionary?)`**: the one-shot raw DEFLATE decoder takes a preset dictionary, as `Decoder` and the core library's `inflate_exact` do.
- **[Moving from MoonBit's core library or moonbit-community/flate](https://github.com/gaato/codecs.mbt/blob/main/deflate/docs/migrating.md)**: the names, errors and behaviour that differ.

### Changed

- **Levels above 9 now select the new tier**, with values above 12 clamped
  to 12; -1 remains the default 6. Migration: callers passing 10 or more
  previously received level 9 and must pass `level=9` to keep that output
  and memory use. zlib FLEVEL is 3 and gzip XFL is 2 at levels 10 to 12.

## [0.3.0] - 2026-11-17

### Added

- **`Decoder::at_block_boundary()`**: whether the input so far ends between two blocks on a byte boundary, with all the output handed out, where a sync flush leaves a stream. A format that cuts a stream at sync flushes and drops their `00 00 ff ff`, as WebSocket's permessage-deflate (RFC 7692) does, can check that a message ended at one: the four bytes appended back can also complete a message cut inside a block without any output.
- **`Decoder::reset(dictionary?)`**: a reset may start the next stream, and those after it, from another preset dictionary. It reuses the window and tables, as a reset without one does, and keeps a view of the dictionary, not a copy.

## [0.2.0] - 2026-11-15

### Added

- **Bounds before encoding or decoding**, in `@deflate`, `@zlib` and `@gzip`: `compress_bound(n)` (for gzip, `compress_bound(n, header?)`), the most `compress` writes for `n` bytes; `encoder_memory_bound(level~)` (gzip's with `header?`) and `decoder_memory_bound()` (gzip's with `keep_header~` and `max_header_bytes~`), what an encoder and a decoder hold.
- **`window_bits` (8 to 15) for the raw DEFLATE and zlib encoders.** Every match then reaches fewer than `1 << window_bits` bytes back, so a decoder that keeps only that much history reads the stream, as WebSocket's permessage-deflate (RFC 7692) negotiates with `server_max_window_bits` and `client_max_window_bits`; zlib's header says the window in CINFO. The default, 15, gives the same bytes as before, and the encoder's memory does not change with the window.

### Changed

- **Level -1 is the default level, 6, as zlib's `Z_DEFAULT_COMPRESSION` is.** It was clamped to 0, so a stream asked for with zlib's spelling of the default was stored, not compressed. `@deflate`, `@zlib` and `@gzip`'s `Encoder` and `compress` all take it; zlib's FLEVEL and gzip's XFL follow, so `@zlib.compress(input, level=-1)` begins `78 9c` as zlib's does. Other levels outside 0 to 9 are still clamped, and the output at every other level is unchanged. Migration: a caller that wants the stored output it got at -1 passes `level=0`.
- **Building a Huffman code sorts its most frequent symbols by heapsort, as libdeflate does.** They were sorted by insertion, which takes time quadratic in their number; a code of 704 symbols now takes about a third of the time on Wasm and half on Native. The output does not change.
- **Error messages.** The messages of `Truncated` and `TrailingData` read the same way as in the other modules: "the input holds no ..." or "the input ends inside ...", and "data after ..." the last unit. Raw DEFLATE says "the input ends inside the DEFLATE data" (it said "the DEFLATE data ends early") and "data after the final block" in every case; zlib "the input ends inside the header or the trailer"; gzip "the input ends inside a member's header" or "... trailer". The kinds are unchanged.
### Fixed

- **The README says which codes are proved:** the fixed Huffman code's canonical codes; the codes the encoder builds for each block (`CodeMaker`, libdeflate's method) are tested, as PROOFS.md lists them, not proved.
- **gzip's `memory_usage` counts the room a header's name or comment has allocated,** not only its bytes: a name read in pieces grew by doubling past what was counted (a name of 32,769 bytes with `max_header_bytes=32769` held 65,536 and was counted as 32,769). The fields now grow no further than `max_header_bytes` leaves them and are trimmed once complete, so the bound, `46,592 + max_header_bytes`, holds for what is allocated.

## [0.1.2] - 2026-11-15

### Changed

- **The encoder is faster on native and Wasm.** Its match finder reads its tables without index checks, rebases them without branches and extends matches sixteen bytes at a time with SIMD (the shared `match_length_fast` of parts/): level 6 compresses the benchmark text (512 KiB) in 13.8 ms in place of 15.7 ms on native and 24.3 in place of 33.1 ms on Wasm, 22.5 in place of 24.6 ms on Wasm GC. JS is unchanged, and the output is the same on all four.
- The decoder copies matches eight bytes at a time, and gzip's CRC-32 reads its tables and input without index checks: in a separate benchmark, the CRC of 512 KiB took 0.53 ms in place of 1.25 ms on Wasm and 0.48 in place of 0.68 ms on Wasm GC. Decoding the benchmark text takes 3.20 ms in place of 3.77 ms on JS, and about as long as before on the other targets. The output and the errors are unchanged.

## [0.1.1] - 2026-11-14

### Changed

- gzip's CRC-32 is computed eight bytes at a time (slice-by-8), from 9 KiB of tables computed at start-up and shared by every decoder and encoder, in place of 1 KiB. The output and the errors are unchanged.
- **The README is about using the module.** Install, Usage, Packages, gzip, zlib, Streams that do not end, Limits, Errors and Links; links are absolute, so they work on mooncakes.io. The compression ratio table and how the levels follow libdeflate's moved to `docs/compression.md`, the exact memory figures are in RESOURCE_BOUNDS.md, and the checks against zlib and libdeflate in TEST_COVERAGE.md. The `gaato/codec_bytes` trait methods and `Header`'s derived methods have doc comments, and the repository-only `scripts/` and `docs/` are no longer packaged.
- zlib's decoder computes the Adler-32 sixteen bytes at a time with SIMD on native and Wasm (core's `@v128`, experimental): the 590,208 bytes of a 512 × 384 RGB image take 51 µs in place of 296 µs on native and 50 µs in place of 658 µs on Wasm. JS and Wasm GC, where SIMD does not pay, keep the byte-at-a-time loop; the encoder keeps the proved `update_bytes`. The output and the errors are unchanged.

### Fixed

- **mooncakes.io shows the README once.** The README was both the module README and the root package's `README.mbt.md`, so the module page showed it twice; it is now `src/overview.mbt.md`, with `README.md` linked to it and named in `moon.mod`.
- zlib's decoder no longer wraps an index past the largest `Int` while summing the Adler-32 of a single piece of output of nearly 2 GiB (from 2,147,478,096 bytes), where it read before the data.

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
