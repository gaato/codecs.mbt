# Changelog

All notable changes to `gaato/crc` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.1.0] - 2026-11-16

### Added

- **CRCs of up to 64 bits.** `Crc::new` from Ross Williams's parameters, `Crc::named` for the 112 CRCs of the reveng catalogue of at most 64 bits by name or alias, `checksum`, `update` (zlib's way of continuing a CRC), `combine` (the CRC of two pieces from theirs, in logarithmic time) and `Digest` for data in pieces. `Crc::try_new` checks parameters that come from data, with the reason when they make no CRC. Every named CRC gives the catalogue's check value, those of whole-byte widths its residue too, and each agrees with the CRC computed bit by bit from its definition.
- **CRC-32, CRC-32C and CRC-64/XZ eight bytes at a time**: `crc32`, `crc32c` and `crc64_xz`, and `crc32_update`, `crc32c_update` and `crc64_xz_update`. CRC-32 agrees with Python's `zlib.crc32`.
