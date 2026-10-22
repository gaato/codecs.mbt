# Test coverage ledger

Line coverage of `gaato/png`, measured on native with `moon test
--enable-coverage` and reported in Coveralls-JSON mode. The rule is a closed
ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.mbtx` enforces this: a file with uncovered
> lines must have a row here whose budget is at least the actual count, and
> the script fails otherwise. Rows for fully covered files are flagged as
> stale and rows with slack are noted, so budgets only ever shrink.

## Running it

```sh
moon run scripts/coverage_report.mbtx -- png   # measure, print tables, check the ledger
moon run scripts/coverage_report.mbtx -- png --from-json _build/coverage_report.png.json   # recheck only
```

CI runs it after the gates on every push and pull request. Exit status: 0 =
ledger OK, 1 = an unexplained or over-budget file, 2 = the run itself failed
(a failing test, a build error).

### What is measured

- Sources: every non-test `.mbt` of the package `src/`, and of the copy of
  the shared part `src/internal/crc32/` (generated from `parts/`, with its
  tests).
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

The pitfalls the script pins (stale counters, `-f summary` skewing totals,
tcc on openSUSE) are described in zstd's ledger, `zstd/TEST_COVERAGE.md`.

The decoder is not written yet; every line measured so far, those of the
CRC-32, is covered.

## Accepted uncovered

| File | Budget | Reason |
|---|---|---|
