# Changelog

All notable changes to `gaato/brotli` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.4.1] - 2026-10-21

### Changed

- The scripts that generate `src/static_data.mbt` and `src/vectors_wbtest.mbt`, and the cross-check of the encoder with google/brotli's decoder, are MoonBit scripts (`scripts/*.mbtx`, run with `moon run`) instead of Python ones; they use google/brotli through the `brotli` command and Node's zlib. The four vectors made from seeded pseudo-random inputs (`gen/window24_far`, `gen/random_window10`, `gen/samples16`, `gen/transforms`) have new contents and test the same things.
- **A step that raises hands out the output before the error and reports it**, as gaato/codec_bytes 0.1.1 asks, which the module now requires. Before, such a step reported zero consumed and zero produced, and output decoded but not yet handed out was lost, so how much came out before an error depended on how the input was split: none when a corrupt stream came in one step. Now `step` first writes everything decoded before the error, answering `NeedMoreOutput` while it does not fit, then raises with `last_consumed()` and `last_produced()` counting that step; on `TrailingData`, `last_consumed()` stops exactly at the end of the stream. The steps after an error raise it again and report zero, as before. Migration: a loop that stops at the first error needs no change; to keep the output before an error, also read `out[:last_produced()]` when a step raises, and expect `NeedMoreOutput` before the error when the slice is small.

## [0.4.0] - 2026-10-20

### Added

- `Decoder` implements `Decode` and `Encoder` implements `Encode` from `gaato/codec_bytes`, the contract the codecs of codecs.mbt share, so code written once against it drives them. The module now depends on `gaato/codec` and `gaato/codec_bytes`.
- `until` on `Decoder` (`EndOfInput` by default). With `EndOfMember`, `step` answers `Done` right after the stream's last meta-block and consumes nothing after it, so `input[last_consumed():]` is what follows the stream.
- `Decoder::memory_usage` and `Encoder::memory_usage`: the bytes held in buffers sized by the stream (the window and the prefix code tables; the input buffer and the waiting output). RESOURCE_BOUNDS.md gives their bounds in terms of the options.

### Changed

- **Errors are `gaato/codec`'s `CodecError(kind, message)`**, from `Decoder::step`, `Decoder::step_into` and `decompress`, the same error every codec of codecs.mbt raises. `Truncated`, `Corrupt` and `TrailingData` keep their names. `WindowTooLarge` becomes `LimitExceeded` with resource `Memory`, `needed` the window the stream declares and `limit` the largest one `max_window_bits` allows, both in bytes as `(1 << WBITS) - 16`. `OutputLimitExceeded` from `decompress` becomes `LimitExceeded` with resource `Output` and `max_output` as `limit`. Migration: add `gaato/codec` to your imports and catch `@codec.CodecError(kind, message)` instead of `@brotli.BrotliError(kind, message)`; match `LimitExceeded(limit)` where you matched `WindowTooLarge` or `OutputLimitExceeded`, and tell them apart by `limit.resource`. `@codec.ErrorKind` is `#non_exhaustive`, so a `match` on it keeps a catch-all arm.
- **`Status` and `EncodeAction` are `gaato/codec_bytes`'s**, re-exported, with the same constructors. `@brotli.Status` and `@brotli.EncodeAction` still name the types, and `@brotli.Status::Done` and an unqualified `Done` (where the type is known) still work, but `@brotli.Done` no longer compiles. Migration: write `Done`, `Continue` and the other constructors unqualified, or as `@brotli.Status::Done` and `@brotli.EncodeAction::Finish`.
- **`end` has no default on `Decoder::step` and `Decoder::step_into`**: a call that left it out decoded as if more input could follow, and a stream cut short then waited for input instead of raising `Truncated`. Migration: pass `end=false` where you relied on the default, and `end=true` with the last input.
- **`action` has no default on `Encoder::step` and `Encoder::step_into`**, for consistency with `Decoder::step`'s `end` and with `gaato/codec_bytes`'s `Encode`. Migration: pass `action=Continue` where you relied on the default.
- **`Done` needs `end`.** A decoder that reaches the end of the stream in a step without `end=true` now answers `NeedMoreInput` (or `NeedMoreOutput` while output waits), since more bytes would still be trailing data; a step with `end=true` and no more bytes then answers `Done`. Before, it answered `Done` at once. `decompress` and `until=EndOfMember` are not affected. Migration: a loop that stops on `Done` passes `end=true` with the last input, or makes one more step with no input and `end=true`.
- The README no longer calls the large window a non-RFC format: it is part of Shared Brotli (RFC 9841), which is not implemented, and its streams still raise `Corrupt`.

### Removed

- `BrotliError` and `BrotliErrorKind`, replaced by `gaato/codec`'s `CodecError` and `ErrorKind` (see Changed). Migration: as for the change to `CodecError` above.

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
