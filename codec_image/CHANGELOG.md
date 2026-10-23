# Changelog

All notable changes to `gaato/codec_image` are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the
version is 0.x, a minor release (0.x → 0.y) may contain breaking changes; a
patch release never does. Every breaking change is listed with a migration
note.

## [Unreleased]

## [0.1.0] - 2026-10-23

### Added

- `Status`, with the eight answers of an image decoder's step: `Header`, `Frame`, `Rows`, `Metadata`, `FrameEnd`, `Done`, `NeedMoreInput` and `NeedMoreOutput`. A step that writes answers `Rows` or `Metadata`; every other answer, and a step that raises, writes nothing.
- `Until`, with `EndOfInput` and `EndOfMember`.
- The `Decode` trait: `step`, `last_consumed`, `last_produced`, `reset` and `memory_usage` as for byte streams; `room_needed`, the smallest slice the next step can write into; the canvas (`width`, `height`), the current frame's rectangle (`frame_x`, `frame_y`, `frame_width`, `frame_height`), and where the last `Rows` lie (`pass` and its lattice `pass_x`, `pass_y`, `pass_dx`, `pass_dy`; `rows_first`, `rows_count`, `row_bytes`).
- `CodecError`, `ErrorKind`, `Limit` and `Resource` of `gaato/codec`, re-exported, so that a consumer names them with `gaato/codec_image` as its only import.
