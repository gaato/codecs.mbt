# Changelog

All notable changes to `gaato/codec` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

### Changed

- **The README has sections and a compile-checked example.** It has Install, Usage (handling a `CodecError` by its kind), the error kinds, and Links, and lives in `src/overview.mbt.md`, linked as `README.md`, so its example is compiled by `moon test`. The derived `equal`, `not_equal` and `to_repr` methods have doc comments.

## [0.1.0] - 2026-10-20

### Added

- `ErrorKind`, `Limit`, `Resource` and `CodecError`.
