# Changelog

All notable changes to `gaato/crc` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.1] - 2026-11-21

### Changed

- **Faster on Wasm, Wasm GC and JS**, with the same values: a model that reflects both its input and its output skips both reflections; on Wasm and JS, models of up to 32 bits run on a 32-bit table and register; on JS, CRC-64/XZ runs as two 32-bit halves; and on Wasm the CRC-32 and CRC-32C loops make no calls. Over 512 KiB on JS, CRC-32/BZIP2 took 25.5 ms, now 1.3; CRC-64/XZ, 24.4 ms, now 0.83; a reflected CRC-16 fed 1 byte at a time, 1,166 ms, now 16. Native keeps its code, which the first two changes made slower there.
- **The README is rewritten** with complete examples.

### Fixed

- **The README's link to the reveng catalogue reads as a sentence**: the tests hold every named CRC to its check value, and every CRC of whole bytes to its residue.

## [0.1.0] - 2026-11-16

### Added

- **CRCs of up to 64 bits.** `Crc::new` from Ross Williams's parameters, `Crc::named` for the 112 CRCs of the reveng catalogue of at most 64 bits by name or alias, `checksum`, `update` (zlib's way of continuing a CRC), `combine` (the CRC of two pieces from theirs, in logarithmic time) and `Digest` for data in pieces. `Crc::try_new` checks parameters that come from data, with the reason when they make no CRC. Every named CRC gives the catalogue's check value, those of whole-byte widths its residue too, and each agrees with the CRC computed bit by bit from its definition.
- **CRC-32, CRC-32C and CRC-64/XZ eight bytes at a time**: `crc32`, `crc32c` and `crc64_xz`, and `crc32_update`, `crc32c_update` and `crc64_xz_update`. CRC-32 agrees with Python's `zlib.crc32`.
