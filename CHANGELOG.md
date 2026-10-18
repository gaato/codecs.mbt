# Changelog

All notable changes to `gaato/zstd` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

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
