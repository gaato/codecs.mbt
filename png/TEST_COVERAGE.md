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

- Sources: every non-test `.mbt` of the package `src/` (the decoder's state
  machine), of its internal packages `src/internal/rules/` (chunk types and
  their order, IHDR's fields, row sizes, Adam7's passes) and
  `src/internal/filter/` (the filters' reverse), and of the copy of the
  shared part `src/internal/crc32/` (generated from `parts/`, with its
  tests).
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

The pitfalls the script pins (stale counters, `-f summary` skewing totals,
tcc on openSUSE) are described in zstd's ledger, `zstd/TEST_COVERAGE.md`.

Snapshot at the last full measurement (2026-10-22): **100.0 %** (375/375
lines).

## Policy

Must be covered by tests:

- every refusal: each malformed signature, IHDR field, chunk frame, chunk
  order, PLTE, CRC, zlib stream and filter type, built chunk by chunk in
  `src/fixtures_wbtest.mbt`;
- every placement of table 7, checked against the table written out again
  (`src/internal/rules/rules_test.mbt`), and every pass of Adam7 against
  counting its lattice;
- every color type and bit depth, interlaced or not, at every size up to
  8 x 8, under several splits of input and output.

Beyond this module's tests, the private conformance module runs the decoder
over PngSuite: every valid image against pypng's samples and typst's
`decode_png`, under the harness's checks of splits, truncation, trailing
bytes, `until=EndOfMember`, `reset` and corruption, and the broken images
against the kinds of error their names describe.

## Accepted uncovered

| File | Budget | Reason |
|---|---|---|
