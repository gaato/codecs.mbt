# Changelog

All notable changes to `gaato/zstd` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

### Fixed

- **One to three bytes after the last frame that begin no magic number** (a lone `0xFF`, or `28 B6`) raise `TrailingData`, with `last_consumed()` at the end of the stream, as soon as they are seen; they raised `Truncated` at the end of the input, as if they began a frame.

## [0.5.0] - 2026-11-15

### Added

- **Bounds before encoding or decoding.** `compress_bound(n)`, the most `compress` or an `Encoder` writes for `n` bytes (3 bytes for each block of at least 1 KiB, the longest frame header and the checksum; 3 more for each `Flush`); `decoder_memory_bound(max_window_bits~)` and `encoder_memory_bound(level~, content_size?, dictionary_len~)`, the most `memory_usage` reports for a decoder or an encoder with those options. The tests check every encoder and decoder they drive against them.
- **Formatted dictionaries**, as `zstd --train` writes them (RFC 8878 section 5). `Dictionary::parse(bytes)` reads one, with its id, its Huffman and FSE tables and its repeat offsets, and takes anything without the magic number as raw content, as `zstd -D` does; it raises `Corrupt` for tables that do not parse or repeat offsets outside the content. The decoder starts each frame that uses it from its tables and offsets, as zstd's does; the encoder writes its id in the frame header and starts from them too, so a first block can code its literals treeless and repeat the dictionary's sequence tables. Frames both ways agree with `zstd -D` and Node's zstd.
- **Raw-content dictionaries in the encoder.** `Encoder(dictionary=d)` and `compress(dictionary=d)` put the dictionary before the frame as `zstd -D` does (zstd's dictionary copied into the window): matches reach into it until a block ends a window past it, and the parameters are chosen for the input and the dictionary together, as zstd chooses them. The frames decode with `zstd -d -D` and Node's zstd, and on records of 100 bytes to 100 KB come out 0.4 % larger to 11 % smaller than `zstd -D`'s at the same level. The encoder copies the dictionary's content into its history at the start of every frame, so its memory grows by about twice the dictionary's length; without a dictionary, nothing changes.
- **Raw-content dictionaries in the decoder.** `Dictionary::raw(content)`, given to `Decoder(dictionary=d)` or `decompress(dictionary=d)`, comes as if just before every frame's output, as RFC 8878 section 5 has it: frames made with `zstd -D` decode, and so do those of RFC 9842's `dcz` coding. As in zstd's decoder, a match may reach into the dictionary however long the frame is. A frame that names another dictionary raises `DictionaryMismatch`; without one it raises `DictionaryRequired(Some(id))`, as before. The dictionary is held by reference, not copied, and `memory_usage` does not count it.
- **The negative levels**, zstd's faster ones: `level=-N` is `zstd --fast=N`, down to -131072, from the row zstd keeps for them, with an acceleration of N and literals left uncoded, as zstd does. They round-trip through `zstd -d`, and the output at levels 1 to 12 is unchanged.
- **Frames read without decoding them.** `inspect_frame` reads the header of the frame at the start of some bytes (`Frame`: a Zstandard frame's `FrameInfo` with its window, content size, dictionary id, checksum flag and header length, or a skippable frame's variant and size), and `frame_size` walks its block headers to where it ends, as zstd's `ZSTD_findFrameCompressedSize` does. `skippable_frame` writes a skippable frame, as RFC 9842's `dcz` coding begins with, and `read_skippable_frame` reads one back. They raise `Truncated` for a frame cut short and `Corrupt` for a header or a block type that RFC 8878 reserves.

### Changed

- **The decoder's `memory_usage` counts its Huffman and FSE tables too,** 13,156 bytes allocated with the decoder, as the encoder's and the other modules' count everything they allocate; it was the window and the block buffers only. A dictionary, held by reference, is still not counted. Migration: a caller that compares `memory_usage` with a limit of its own allows 13,156 bytes more.
- **Level 0 is the default level, 3, as in zstd.** It acted as 1. Migration: a caller that wants what level 0 gave passes `level=1`.
- **Building a literals' Huffman code sorts its most frequent symbols by heapsort, as libdeflate does.** They were sorted by insertion, which takes time quadratic in their number; encoding the benchmarks' inputs takes up to 19 % less time on Native at the higher levels. The output does not change.
- **Error messages.** The messages of `Truncated` and `TrailingData` read the same way as in the other modules: "the input holds no ..." or "the input ends inside ...", and "data after ..." the last unit. `Truncated` says "the input holds no frame" or "the input ends inside a frame" (it said "the stream ..."); `TrailingData` says "data after the last frame". The kinds are unchanged.
### Fixed

- **RESOURCE_BOUNDS.md's bound for the encoder's waiting output counts the magic number and a 14-byte frame header,** with a dictionary id: it said 131,093 bytes and is 131,097, which puts the largest encoder at 52,460,456 bytes, not 52,460,448.

## [0.4.1] - 2026-11-15

### Changed

- **The decoder is two to three times as fast.** It hashes the content checksum once per block, reads 64 bits at a time and executes each block's sequences in one loop with eight-byte copies on native and Wasm, decodes the four Huffman streams of the literals interleaved on all targets but JS, and on JS computes XXH64 in 32-bit halves instead of BigInts. The benchmark text (512 KiB, made by `zstd -3`) decodes in 1.82 ms in place of 4.73 ms on native, 4.02 in place of 10.47 ms on Wasm, 4.36 in place of 8.04 ms on Wasm GC and 10.3 in place of 31.7 ms on JS. The output and the errors are unchanged; a malformed literals section still raises the error of its first bad stream.
- **The encoder is 1.6 to 5 times as fast on JS**, the most at the low levels. Its hashes no longer use 64-bit integers there, which are BigInts: the benchmark text takes 31.4 ms in place of 143 ms at level 3, 29.2 in place of 106 ms at level 1 and 205 in place of 323 ms at level 12. The other targets are unchanged, and the output is the same on all four.

## [0.4.0] - 2026-11-14

### Added

- **An encoder.** `Encoder` (streaming, `gaato/codec_bytes`'s `Encode`, with `Continue`, `Flush` and `Finish`) and `compress` write one Zstandard frame at zstd's levels 1 to 12, 3 by default, with zstd 1.5.7's parameters for each level and input size: fast, double-fast, and greedy, lazy and lazy2 searching rows of tags as zstd does (hash chains for windows of at most 16 KiB, and for the small-input rows of levels 9 to 12 where zstd uses binary trees, which are not implemented). Raw, RLE and compressed blocks, Huffman-coded literals and FSE-coded sequences, the XXH64 content checksum unless `checksum=false`, and the content size when it is known (`compress`, or `Encoder(content_size=n)`, which then raises `ChecksumMismatch` when the input does not match it). On the Silesia and Canterbury corpora the totals are within 1 % of `zstd -N`'s at every level, and the output does not depend on how input and output are split. Levels 13 to 22 act as 12; dictionaries are not supported. `EncodeAction` is re-exported from `gaato/codec_bytes`. [docs/compression.md](https://github.com/gaato/codecs.mbt/blob/main/zstd/docs/compression.md) describes each level and its measurements.

### Changed

- **The README has sections.** Install, Usage, What it decodes, Encoding, Memory, Errors and Links; links are absolute, so they work on mooncakes.io. How the proofs are run is left to PROOFS.md. The `gaato/codec_bytes` trait methods have doc comments, and the repository-only `scripts/` is no longer packaged.

### Fixed

- **mooncakes.io shows the README once.** The README was both the module README and the root package's `README.mbt.md`, so the module page showed it twice; it is now `src/overview.mbt.md`, with `README.md` linked to it and named in `moon.mod`.

## [0.3.1] - 2026-10-22

### Changed

- **A step that raises hands out the output before the error and reports it**, as gaato/codec_bytes 0.1.1 asks, which the module now requires. Before, such a step reported zero consumed and zero produced, and output decoded but not yet handed out was lost, so how much came out before an error depended on how the input was split: none when a corrupt stream came in one step. Now `step` first writes everything decoded before the error, answering `NeedMoreOutput` while it does not fit, then raises with `last_consumed()` and `last_produced()` counting that step; on `TrailingData`, `last_consumed()` stops exactly at the end of the stream. The steps after an error raise it again and report zero, as before. Migration: a loop that stops at the first error needs no change; to keep the output before an error, also read `out[:last_produced()]` when a step raises, and expect `NeedMoreOutput` before the error when the slice is small.

## [0.3.0] - 2026-10-20

### Fixed

- A stream whose literals use four Huffman streams for fewer than 6 literals raises `Corrupt`, as RFC 8878 erratum 7297 and the reference decoder require; regenerated sizes 0, 3 and 4 were accepted.

### Changed

- **Errors are `gaato/codec`'s `CodecError`.** Every function and method raises `@codec.CodecError(kind, message)` with an `@codec.ErrorKind`, the error every codec of codecs.mbt raises. Migration: add `gaato/codec` to your imports, then `ZstdError(kind, msg)` → `@codec.CodecError(kind, msg)`; `WindowTooLarge` → `LimitExceeded({ resource: Memory, needed: Some(window), limit })`, where `limit` is `1 << max_window_bits`; `OutputLimitExceeded` → `LimitExceeded({ resource: Output, needed: None, limit: max_output })`; `DictionaryUnsupported` → `DictionaryRequired(Some(id))`, with the dictionary id the frame names. `Truncated`, `Corrupt` and `ChecksumMismatch` keep their names.
- **Bytes after the last frame raise `TrailingData`**, not `Corrupt`: four bytes after a frame (or a skippable frame) that start no frame, and any bytes after a stream that has ended. Bytes that start no frame at the very beginning are still `Corrupt` (not a zstd stream), and fewer than four bytes after the last frame are still `Truncated`. Migration: code that took `Corrupt` for garbage after the stream matches `TrailingData`.
- **`end` is required** on `Decoder::step` and `Decoder::step_into`; it no longer defaults to `false`, since a caller that forgets it would get a silently truncated stream. Migration: pass `end=false` where the default was relied on.
- **`Status` is `gaato/codec_bytes`'s**, re-exported as `@zstd.Status`, with the same constructors. Migration: `@zstd.Done` no longer resolves; write `Done` where the type is known, or `@zstd.Status::Done`.

### Added

- `Decoder` implements `gaato/codec_bytes`'s `Decode`, so code written against that contract drives it like any other decoder of codecs.mbt.
- `Decoder(until=EndOfMember)` stops right after the first frame (a skippable frame counts as one) and consumes nothing past it, so `input[last_consumed():]` is what follows; `end=true` before that frame is complete raises `Truncated`. The default, `until=EndOfInput`, decodes every frame up to the end of the input, as before.
- `Decoder::memory_usage`: the bytes held in the window and the block buffers, at most `(1 << max_window_bits) + 256 KiB`. It may drop between frames.

### Removed

- `ZstdError` and `ZstdErrorKind`, replaced by `gaato/codec`'s `CodecError` and `ErrorKind` (see Changed).

## [0.2.0] - 2026-10-19

### Changed

- **`ZstdErrorKind` is `#non_exhaustive`.** A later kind of failure, such as
  one for dictionary support, can then be told apart without breaking
  matches in your code. Migration: a `match` on `ZstdErrorKind` ends with
  `@zstd.ZstdErrorKind::.. => …` after the existing constructors. `Status`
  stays exhaustive.

## [0.1.0] - 2026-10-19

### Added

- `Decoder`, a streaming RFC 8878 decoder: `step` (into a `MutArrayView`) and
  `step_into` (into a `FixedArray`) take input in chunks of any size and
  write output into buffers of any size, answering `Status` (`Done`,
  `NeedMoreInput`, `NeedMoreOutput`); `end=true` marks the last input.
  `last_consumed`, `last_produced`, `is_finished` and `reset`.
- Several frames in a row and skippable frames; content checksums (XXH64)
  and content sizes are checked.
- `max_window_bits` on `Decoder` and `decompress` (27 by default): frames
  needing a larger window raise `WindowTooLarge` before anything is
  allocated.
- `decompress`, a one-shot decoder with an optional `max_output`.
- `ZstdError(ZstdErrorKind, String)` for every malformed stream:
  `Truncated`, `Corrupt`, `ChecksumMismatch`, `WindowTooLarge`,
  `DictionaryUnsupported` and `OutputLimitExceeded`.
