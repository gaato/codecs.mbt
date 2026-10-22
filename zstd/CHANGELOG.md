# Changelog

All notable changes to `gaato/zstd` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

### Changed

- **The README has sections.** Install, Usage, What it decodes, Memory, Errors and Links; links are absolute, so they work on mooncakes.io. How the proofs are run is left to PROOFS.md. The `gaato/codec_bytes` trait methods have doc comments, and the repository-only `scripts/` is no longer packaged.

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
