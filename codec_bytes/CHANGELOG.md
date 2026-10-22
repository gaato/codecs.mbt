# Changelog

All notable changes to `gaato/codec_bytes` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the
version is 0.x, a minor release (0.x → 0.y) may contain breaking changes; a
patch release never does. Every breaking change is listed with a migration
note.

## [Unreleased]

### Changed

- **The README has sections and a compile-checked example.** It has Install, Usage (a loop that drives any `Decode`, run on a small identity decoder), Errors, and Links, and lives in `src/overview.mbt.md`, linked as `README.md`, so its examples are compiled by `moon test`. The re-exports of `gaato/codec`'s types are one `pub using` each, with its own doc comment, and the derived methods have doc comments; the interface is unchanged.

## [0.1.1] - 2026-10-22

### Added

- `CodecError`, `ErrorKind`, `Limit` and `Resource` of `gaato/codec`, re-exported, so that a consumer names them with `gaato/codec_bytes` as its only import. Constructors match unqualified where the type is known, as in a `catch` on a step, or qualified by their type, as in `@codec_bytes.CodecError::CodecError(kind, _)`.

### Changed

- **A step that raises reports what it did before the error.** `last_consumed` and `last_produced` now count what such a step consumed and wrote, instead of zero. A codec first writes all the output the input determines before the error; when the slice fills before that, the step answers `NeedMoreOutput`, and a later one writes the rest and raises. For `TrailingData`, `last_consumed` stops exactly at the end of the stream. Errors still stick: later steps raise the same kind and report zero. So a corrupt stream gives the same output, then the same kind of error, however it is split (rule 5 of CONTRACT.md now says so). The types are unchanged; the traits' documentation states the rule. Migration: code that stops at the first error needs no change; code that wants the output before an error also reads `out[:last_produced()]` when a step raises, and expects `NeedMoreOutput` before the error when its slice is small.

## [0.1.0] - 2026-10-20

### Added

- `Status`, `Until`, `EncodeAction`, and the `Decode` and `Encode` traits.
