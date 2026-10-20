# Changelog

All notable changes to `gaato/brotli` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.3.0] - 2026-10-19

### Changed

- **`BrotliErrorKind` is `#non_exhaustive`.** A later kind of failure can
  then be told apart without breaking matches in your code. Migration: a
  `match` on `BrotliErrorKind` ends with `@brotli.BrotliErrorKind::.. => …`
  after the existing constructors. `Status` stays exhaustive.

## [0.2.0] - 2026-10-19

### Added

- `Encoder`, a streaming RFC 7932 encoder: `step` (into a `MutArrayView`)
  and `step_into` (into a `FixedArray`) take input in chunks of any size and
  write output into buffers of any size, answering `Status`; an
  `EncodeAction` (`Continue`, `Flush`, `Finish`) says what to do once the
  input is taken. `Flush` makes the output so far decode to the input so
  far. `last_consumed`, `last_produced`, `is_finished` and `reset`, as for
  `Decoder`.
- `window_bits` on `Encoder` and `compress` (22 by default, 10..24).
- `compress`, a one-shot encoder; it declares no larger a window than the
  input needs.
- Greedy LZ77 with one-byte lazy matching and one prefix code per category
  in each 64 KiB meta-block: about google/brotli's quality 4. Meta-blocks
  that do not compress are stored uncompressed.
- `scripts/crosscheck.py`, run by CI, decodes the encoder's streams with
  google/brotli's decoder.

### Changed

- The README's examples are tested: the README is `src/README.mbt.md`,
  whose code blocks `moon test` compiles and runs on a real stream, and the
  root `README.md` links to it.

## [0.1.0] - 2026-10-18

### Added

- `Decoder`, a streaming RFC 7932 decoder: `step` (into a `MutArrayView`) and
  `step_into` (into a `FixedArray`) take input in chunks of any size and
  write output into buffers of any size, answering `Status` (`Done`,
  `NeedMoreInput`, `NeedMoreOutput`); `end=true` marks the last input.
  `last_consumed`, `last_produced`, `is_finished` and `reset`.
- `max_window_bits` on `Decoder` and `decompress` (24 by default): streams
  needing a larger window raise `WindowTooLarge`.
- `decompress`, a one-shot decoder with an optional `max_output`.
- `BrotliError(BrotliErrorKind, String)` for every malformed stream:
  `Truncated`, `Corrupt`, `TrailingData`, `WindowTooLarge` and
  `OutputLimitExceeded`.
