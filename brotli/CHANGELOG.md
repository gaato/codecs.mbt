# Changelog

All notable changes to `gaato/brotli` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). While the version is
0.x, a minor release (0.x → 0.y) may contain breaking changes; a patch release
never does. Every breaking change is listed with a migration note.

## [Unreleased]

## [0.5.0] - 2026-11-15

### Added

- **Bounds before encoding or decoding.** `compress_bound(n)`, the most `compress` writes for `n` bytes (5 bytes a meta-block of 64 KiB and the stream header; 7 more for each `Flush` of an `Encoder`), and `decoder_memory_bound(max_window_bits~)` and `encoder_memory_bound(window_bits~)`, the most `memory_usage` reports for a decoder or an encoder with those options.
- **LZ77 dictionaries in the encoder.** `Encoder(dictionary=d)` and `compress(dictionary=d)` let a match copy from the dictionary, past the window's reach, as `brotli -D` writes and RFC 9842's `dcb` coding reads; a match never runs past the dictionary's end. The streams decode with `brotli -d -D` and Node's zlib. A 314-byte record that shares words with a 50,000-byte dictionary compresses to 100 bytes with it, 201 without, and 95 with `brotli -q 5 -D`. The `Dictionary` builds the index encoders search it with once and shares it: 5 bytes per byte of the dictionary's last 64 MiB at most (the part a distance can reach) and a table of at most 512 KiB (`Dictionary::memory_usage`); without a dictionary, the output is unchanged.
- **LZ77 dictionaries in the decoder** (RFC 9841 section 3.2), as `brotli -D` writes them and RFC 9842's `dcb` coding uses one. `Dictionary(bytes)`, given to `Decoder(dictionary=d)` or `decompress(dictionary=d)`, takes the distances just past the window's reach, before the static dictionary's words, whose ids move up by the dictionary's length. A copy that would run past the dictionary's end raises `Corrupt`, as google/brotli's decoder refuses it; RFC 9841 has it go on into the window, which a full window no longer holds. The dictionary is held by reference, not copied, and `memory_usage` does not count it.

### Changed

- **`memory_usage` counts everything the codec allocated,** as the other modules' do and as CONTRACT.md now says in one way. The encoder's adds the hash table (`16 << min(window_bits, 15)` bytes, 512 KiB from 15 up) and a meta-block's commands, histograms and codes (351,628 bytes); the decoder's adds the context maps and scratch space it is made with (27,793 bytes). RESOURCE_BOUNDS.md gives the new bounds: 6,315,516 bytes for an encoder at `window_bits` 22. Migration: a caller that compares `memory_usage` with a limit of its own allows for the larger figure.
- **The encoder builds its prefix codes as gaato/deflate and gaato/zstd do,** with libdeflate's method (`CodeMaker`, from the repository's shared parts) instead of flooring the frequencies until the optimal code fits, which allocated and sorted for every code. The streams change, and decode as before: the Canterbury corpus comes to 645,891 bytes against 645,860, and each of the benchmarks' text and binary inputs to 1 byte more.
- **Error messages.** The messages of `Truncated` and `TrailingData` read the same way as in the other modules: "the input holds no ..." or "the input ends inside ...", and "data after ..." the last unit. `Truncated` says "the input holds no stream" for empty input and "the input ends inside the stream" otherwise (it said "the stream ends early"); `TrailingData` says "data after the last meta-block". The kinds are unchanged.

### Fixed

- **The README no longer says the encoder's codes are proved.** They are made as libdeflate makes them (`CodeMaker`), which PROOFS.md lists as not proved; the tests hold them to optimal codes.
- **A stream whose input ends on a meta-block's boundary before `Finish` no longer depends on the split.** When a step's input filled a 64 KiB meta-block exactly and `Finish` came in a later step, the encoder wrote that meta-block as not the last and then an empty last one, a byte more than for the same input in one step; it now keeps a full meta-block until the next step says whether more follows.
- **`decompress(max_output=)` cannot overflow and reports a negative limit as 0,** as gaato/zstd's and gaato/deflate's do.
- **The last meta-block's choice between compressed and uncompressed counts the empty last meta-block an uncompressed one needs after it,** 1 byte, so a last meta-block that compresses to within that byte of its size is no longer written uncompressed.

## [0.4.3] - 2026-11-15

### Changed

- **The decoder is faster.** It decodes runs of literals and whole commands in loops that keep the bit reader in place while the input surely holds their bits, refills three bytes at a time, copies short matches eight bytes at a time, and reads its prefix-code tables without index checks. The benchmark text (512 KiB, made by `brotli -q 9`) decodes in 2.57 ms in place of 3.77 ms on native, 4.11 in place of 7.31 ms on Wasm GC and 9.79 in place of 15.95 ms on JS; on Wasm, the binary stream (128 KiB) in 2.83 in place of 6.43 ms and the text in 9.09 in place of 9.99 ms. The loop for whole commands is off on Wasm, where it was slower. The output and the errors are unchanged, however the input is split.
- **The encoder is faster on native and Wasm.** It hashes four bytes read at once, hashes each position once, compares matches sixteen bytes at a time with SIMD on native and Wasm (the shared `match_length_fast` of parts/), and checks a meta-block's size budget once for a run of literals: the benchmark text compresses in 9.08 ms in place of 15.4 ms on native, 22.5 in place of 55.2 ms on Wasm and 15.5 in place of 18.4 ms on Wasm GC. JS is unchanged, and the output is the same on all four.

## [0.4.2] - 2026-11-14

### Changed

- **The README has sections.** Install, Usage, What it decodes, Encoding, Memory, Errors and Links; links are absolute, so they work on mooncakes.io. The cross-check with google/brotli's decoder is described in TEST_COVERAGE.md instead. The `gaato/codec_bytes` trait methods have doc comments, and the repository-only `scripts/` is no longer packaged.
- The encoder writes its bits eight bytes at a time on native, Wasm and Wasm GC (the shared bit writer of parts/bits), 2-5% faster; its output is unchanged.

### Fixed

- **mooncakes.io shows the README once.** The README was both the module README and the root package's `README.mbt.md`, so the module page showed it twice; it is now `src/overview.mbt.md`, with `README.md` linked to it and named in `moon.mod`.

## [0.4.1] - 2026-10-22

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
