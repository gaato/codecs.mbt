# Test coverage

How much of gaato/lz4 its tests run, and why the rest is not run. The
ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.mbtx` enforces this: a file with uncovered
> lines must have a row here whose budget is exactly the actual count, and
> the script fails otherwise, for a row with a larger budget and for one of a
> fully covered file as well: a budget with room to spare would let a line
> that tests stop reaching go unnoticed.

## Running it

```sh
moon run scripts/coverage_report.mbtx -- lz4   # measure, print tables, check the ledger
```

The gates run it (`scripts/gates.mbtx`), on every push and pull request in
CI too. The pitfalls the script pins are described in zstd's ledger,
`zstd/TEST_COVERAGE.md`.

### What is measured

- Sources: every non-test `.mbt` of `src/` (the frame decoder and its
  sequence decoding, the block compressor, the frame encoder, XXH32, the
  whole-input functions and the trait implementations) and of the copies of
  `src/internal/blit/` and `src/internal/copy16/` (generated from `parts/`,
  with their tests). The crosscheck's executable, `src/internal/crosscheck/`,
  is run by `scripts/crosscheck.mbtx` and `scripts/gen_vectors.mbtx`, not by
  the tests.
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

Snapshot at the last full measurement (2026-11-16): **96.4 %** (622/645
lines); the 23 uncovered lines are ledgered below, 21 of them the JS and
Wasm GC variants that native does not compile.

## Policy

Must be covered by tests:

- what lz4 1.10.0's library writes for the crosscheck's inputs in every set
  (`src/vectors_wbtest.mbt`, written by `scripts/gen_vectors.mbtx`): each
  decodes, whole and in pieces, and where the options are lz4's and there is
  no dictionary, the encoder writes the same bytes (with one, the
  crosscheck compares sizes);
- each way a block or a frame breaks the format, the checksums, the content
  size, dictionaries, skippable and legacy frames and `EndOfMember`;
- the limits of a block's output, of `max_output` and of lengths that grow
  by 255s; the room checks after which lz4 stores a block;
- round trips however input and output are split and flushed, with every
  option, within the bounds; memory after every step; the
  `gaato/codec_bytes` traits through generic code.

Accepted as uncovered (needs a row):

- lines that only an `abort` reaches for what cannot happen, or for inputs a
  test cannot allocate;
- code compiled only for another target (JS, Wasm GC), which the gates test
  there.

Budgets are the exact uncovered counts: the script fails on any difference.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
| src/encode.mbt | 16 | `load32`, `load64` and `count_match` for JS and Wasm GC (`#cfg(not(any(target="native", target="wasm")))`), which read bytes one at a time where native and Wasm read four or eight at once (10 lines), and `hash_large` and `mul_high` for JS (`#cfg(target="js")`), which compute lz4's five-byte hash from 32-bit halves where a 64-bit integer would be a BigInt (5 lines); the gates run the same tests there, and the vectors' streams, which these functions write to the byte, hold them to native's. And the `abort` of `compress_block` for inputs over lz4's 2,113,929,216 bytes, which a test cannot allocate. |
| src/encoder.mbt | 1 | JS updates the content checksum as input arrives because hashing the block buffer slowed whole-input encoding there. The frame tests on JS check the checksum against the same reference vectors. |
| src/whole.mbt | 1 | The `abort` of `compress` if the encoder raised: it raises only for a content size, which `compress` does not give it. |
| src/internal/blit/blit.mbt | 10 | `bytes`, `into_view`, `move_down` and `from_view` for JS (`#cfg(target="js")`), forward loops without index checks, and `forward` for JS and Wasm GC, a byte at a time where native and Wasm copy eight: the ledger measures native, which compiles the block copies and the eight-byte steps instead. The gates run the same tests on JS and Wasm GC: `src/internal/blit/blit_test.mbt`, and the decoder's tests, whose overlapping matches `forward` copies. |
| src/internal/copy16/copy16.mbt | 6 | The JS byte loops and Wasm GC block copies are compiled only on their own targets. `src/internal/copy16/copy16_test.mbt` checks both copies on all four targets, including unaligned ranges and a nonzero view origin. |
| src/internal/whole/whole.mbt | 4 | The output reaching 2^31 - 1 bytes with no `max_output` (`None => MAX_LENGTH` in `decode`, the `abort` of `encode`), which no test can allocate, and `copy` for JS (`#cfg(target="js")`), a loop without index checks: the ledger measures native, which compiles the block copy instead. The gates run the same tests on JS: `src/internal/whole/whole_test.mbt`, and every `compress` and `decompress` test of the module. |
| src/xxh32_bulk.mbt | 16 | Wasm GC assembles the four words of a full XXH32 stripe from bytes. Native and Wasm use word loads. The XXH32 vectors and incremental-update tests run on every target, including the JS implementation in `src/xxh32_js.mbt`. |
