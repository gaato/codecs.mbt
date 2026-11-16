# Test coverage

How much of gaato/lzw its tests run, and why the rest is not run. The
ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.mbtx` enforces this: a file with uncovered
> lines must have a row here whose budget is exactly the actual count, and
> the script fails otherwise, for a row with a larger budget and for one of a
> fully covered file as well: a budget with room to spare would let a line
> that tests stop reaching go unnoticed.

## Running it

```sh
moon run scripts/coverage_report.mbtx -- lzw   # measure, print tables, check the ledger
```

The gates run it (`scripts/gates.mbtx`), on every push and pull request in
CI too. The pitfalls the script pins are described in zstd's ledger,
`zstd/TEST_COVERAGE.md`.

### What is measured

- Sources: every non-test `.mbt` of `src/`: the formats, the decoder, the
  encoder, the whole-input functions and the trait implementations. The
  crosscheck's executable, `src/internal/crosscheck/`, is run by
  `scripts/crosscheck.mbtx` and `scripts/gen_vectors.mbtx`, not by the
  tests.
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

Snapshot at the last full measurement (2026-11-16): **100 %** (294/294
lines).

## Policy

Must be covered by tests:

- what weezl and compress write for the crosscheck's inputs
  (`src/vectors_wbtest.mbt`, written by `scripts/gen_vectors.mbtx`): each
  decodes, whole and in pieces, and the encoder writes compress's .Z, and
  weezl's GIF and TIFF where the table does not fill, to the byte;
- every format round-tripping however split, with tables that fill and
  clear; .Z's padding after a clear, byte by byte and cut short; a GIF table
  that fills without a clear;
- each way a stream breaks its format, the formats' ranges, missing end
  codes, `EndOfMember`, `Flush`, the bounds; the `gaato/codec_bytes` traits
  through generic code.

Accepted as uncovered (needs a row): none at present.

Budgets are the exact uncovered counts: the script fails on any difference.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
