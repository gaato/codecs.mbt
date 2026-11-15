# Test coverage

How much of gaato/crc its tests run, and why the rest is not run. The
ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.mbtx` enforces this: a file with uncovered
> lines must have a row here whose budget is exactly the actual count, and
> the script fails otherwise, for a row with a larger budget and for one of a
> fully covered file as well: a budget with room to spare would let a line
> that tests stop reaching go unnoticed.

## Running it

```sh
moon run scripts/coverage_report.mbtx -- crc   # measure, print tables, check the ledger
```

The gates run it (`scripts/gates.mbtx`), on every push and pull request in
CI too. The pitfalls the script pins are described in zstd's ledger,
`zstd/TEST_COVERAGE.md`.

### What is measured

- Sources: every non-test `.mbt` of `src/` and of the copies of the shared
  parts `src/internal/crc32/` and `src/internal/crc32c/` (generated from
  `parts/`, with their tests).
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

Snapshot at the last full measurement (2026-11-16): **86.5 %** (173/200
lines); the 27 uncovered lines are ledgered below, 26 of them the JS and
Wasm GC variants that native does not compile.

## Policy

Must be covered by tests:

- every CRC of the catalogue: its check value and, for whole-byte widths,
  its residue as reveng gives them, and the CRC computed bit by bit from its
  parameters, on data of several lengths (`src/crc_wbtest.mbt`);
- the three fast CRCs against their tables at every alignment and length up
  to 1,024, and CRC-32 against Python's `zlib.crc32`;
- `combine` over random splits for every CRC of the catalogue, and its
  powers of x past 2^31 bytes; `Digest` in pieces.

Accepted as uncovered (needs a row):

- lines that only an `abort` reaches, run by `panic` tests, whose counts the
  abort discards;
- code compiled only for another target (JS, Wasm GC), which the gates test
  there;
- testable lines not yet tested, marked `not yet tested`.

Budgets are the exact uncovered counts: the script fails on any difference.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
| src/crc.mbt | 1 | The `abort` of `Crc::new` for parameters `try_new` refuses (a width outside 1 to 64, a `poly`, `init` or `xor_out` wider than the width): the `panic` tests of `src/crc_wbtest.mbt` run it, but the abort ends the test before its coverage counts are written; "try_new says why parameters make no CRC" covers each refusal. |
| src/internal/crc32/crc32.mbt | 13 | `update_bytes` for JS and Wasm GC (`#cfg(not(any(target="native", target="wasm")))`), which assembles bytes in the caller's loop to preserve those backends' performance. Native compiles the word-load variant instead. The same `crc32_test.mbt` runs on JS and Wasm GC, checking the bitwise reference, offsets 0 to 7, lengths 0 to 64, and CRC continuation across every tested split. `src/crc_wbtest.mbt` compares the fast CRCs with their tables at every alignment and length on all four targets too. |
| src/internal/crc32c/crc32c.mbt | 13 | `update_bytes` for JS and Wasm GC (`#cfg(not(any(target="native", target="wasm")))`), which assembles bytes in the caller's loop to preserve those backends' performance. Native compiles the word-load variant instead. The same `crc32c_test.mbt` runs on JS and Wasm GC, checking the bitwise reference, offsets 0 to 7, lengths 0 to 64, and CRC continuation across every tested split. `src/crc_wbtest.mbt` compares the fast CRCs with their tables at every alignment and length on all four targets too. |
