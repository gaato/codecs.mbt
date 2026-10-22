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
  machine, the fixed-length ancillary chunks and the blocks of reported
  ones), of its internal packages `src/internal/rules/` (chunk types and
  their order, IHDR's fields, row sizes, Adam7's passes) and
  `src/internal/filter/` (the filters' reverse), and of the copy of the
  shared part `src/internal/crc32/` (generated from `parts/`, with its
  tests).
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

The pitfalls the script pins (stale counters, `-f summary` skewing totals,
tcc on openSUSE) are described in zstd's ledger, `zstd/TEST_COVERAGE.md`.

Snapshot at the last full measurement (2026-10-22): **99.7 %** (628/630
lines), the two uncovered lines ledgered below.

## Policy

Must be covered by tests:

- every refusal: each malformed signature, IHDR field, chunk frame, chunk
  order, PLTE, CRC, zlib stream and filter type, built chunk by chunk in
  `src/fixtures_wbtest.mbt`;
- every placement of table 7, checked against the table written out again
  (`src/internal/rules/rules_test.mbt`), and every pass of Adam7 against
  counting its lattice;
- every color type and bit depth, interlaced or not, at every size up to
  8 x 8, under several splits of input and output;
- every check of a fixed-length ancillary chunk's length and values, and of
  a reported chunk's keyword, compression fields and zlib stream, and
  `max_chunk_bytes` both as a chunk comes and as it inflates.

Beyond this module's tests, the private conformance module runs the decoder
over PngSuite: every valid image against pypng's samples and what pypng
reads of gAMA, tRNS, bKGD, pHYs and sBIT, its text chunks against Python's
zlib, and against typst's `decode_png`, under the harness's checks of
splits, truncation, trailing bytes, `until=EndOfMember`, `reset` and corruption, and the broken images
against the kinds of error their names describe; and over animated PNGs
(the Web Platform Tests' png/apng, Wuffs' and image-png's animations),
every frame against the png crate's.

## Accepted uncovered

| File | Budget | Reason |
|---|---|---|
| src/decoder.mbt | 2 | `blit` for JS (`#cfg(target="js")`), which copies a row byte by byte: the ledger measures native, which compiles the block copy instead. The gates run the same tests on JS, among them "step_into writes what step writes, into a whole array". |
