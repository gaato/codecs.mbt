# Test coverage

How much of gaato/snappy its tests run, and why the rest is not run. The
ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.mbtx` enforces this: a file with uncovered
> lines must have a row here whose budget is exactly the actual count, and
> the script fails otherwise, for a row with a larger budget and for one of a
> fully covered file as well: a budget with room to spare would let a line
> that tests stop reaching go unnoticed.

## Running it

```sh
moon run scripts/coverage_report.mbtx -- snappy   # measure, print tables, check the ledger
```

The gates run it (`scripts/gates.mbtx`), on every push and pull request in
CI too. The pitfalls the script pins are described in zstd's ledger,
`zstd/TEST_COVERAGE.md`.

### What is measured

- Sources: every non-test `.mbt` of `src/` (the raw format, the encoder's
  fragments, the framing format's decoder and encoder, the whole-stream
  functions and the trait implementations) and of the copies of the shared
  parts `src/internal/blit/` and `src/internal/crc32c/` (generated from
  `parts/`, with their tests). The crosscheck's executable,
  `src/internal/crosscheck/`, is run by `scripts/crosscheck.mbtx`, not by
  the tests.
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

Snapshot at the last full measurement (2026-11-16): **94.0 %** (343/365
lines); the 22 uncovered lines are ledgered below, 19 of them the JS and
Wasm GC variants that native does not compile.

## Policy

Must be covered by tests:

- every element of the raw format, each way a raw stream breaks it, and the
  checks of the declared length (`src/snappy_wbtest.mbt`);
- framed streams however their input and output are split, with flushes,
  skippable chunks, padding, streams one after another, `EndOfMember`, and
  each way a framed stream breaks the format;
- the streams snap writes for the test data (`src/vectors_wbtest.mbt`,
  written by `scripts/gen_vectors.mbtx`), decoded, and ours as small, to the
  byte;
- the memory bounds after every step, and the `gaato/codec_bytes` traits
  through generic code.

Accepted as uncovered (needs a row):

- lines that only an `abort` reaches: an input whose bound passes what an
  array holds, which a test would need nearly 2 GiB for, and a bound too
  small, which cannot happen;
- code compiled only for another target (JS, Wasm GC), which the gates test
  there.

Budgets are the exact uncovered counts: the script fails on any difference.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
| src/raw.mbt | 1 | The `abort` of `compress_raw` for inputs over 1,840,700,242 bytes, whose bound passes 2^31 - 1 bytes; a test would need an input of 1.7 GiB and an output array past the largest. |
| src/whole.mbt | 2 | The `abort` of `compress` for inputs over 2,147,221,517 bytes, whose bound passes 2^31 - 1 bytes, which a test cannot allocate; and its `abort` if the output did not fit `compress_bound`, which cannot happen: "framed streams round-trip however split, and flushes decode" checks every stream against the bound. |
| src/internal/blit/blit.mbt | 6 | `bytes` and `into_view` for JS (`#cfg(target="js")`), forward loops without index checks, and `forward` for JS and Wasm GC, a byte at a time where native and Wasm copy eight: the ledger measures native, which compiles the block copies and the eight-byte steps instead. The gates run the same tests on JS and Wasm GC: `src/internal/blit/blit_test.mbt`, and the raw tests' copies, overlapping ones among them, which `forward` makes. |
| src/internal/crc32c/crc32c.mbt | 13 | `update_bytes` for JS and Wasm GC (`#cfg(not(any(target="native", target="wasm")))`), which assembles bytes in the caller's loop to preserve those backends' performance. Native compiles the word-load variant instead. The same `crc32c_test.mbt` runs on JS and Wasm GC, checking the bitwise reference, offsets 0 to 7, lengths 0 to 64, and CRC continuation across every tested split; the framed tests check every chunk's CRC-32C on all four targets too. |
