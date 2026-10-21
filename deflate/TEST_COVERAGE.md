# Test coverage ledger

Line coverage of `gaato/deflate` (the raw DEFLATE, zlib and gzip packages),
measured on native with `moon test --enable-coverage` and reported in
Coveralls-JSON mode. The rule is a closed ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.mbtx` enforces this: a file with uncovered
> lines must have a row here whose budget is at least the actual count, and
> the script fails otherwise. Rows for fully covered files are flagged as
> stale and rows with slack are noted, so budgets only ever shrink.

## Running it

```fish
moon run scripts/coverage_report.mbtx -- deflate   # measure, print tables, check the ledger
moon run scripts/coverage_report.mbtx -- deflate --from-json _build/coverage_report.deflate.json   # recheck only
```

CI runs it after the gates on every push and pull request. Exit status: 0 =
ledger OK, 1 = an unexplained or over-budget file, 2 = the run itself failed
(a failing test, a build error). The tests are deterministic: fixed vectors,
streams built bit by bit, and seeded pseudo-random splits and corruptions.

### What is measured

- Sources: every non-test `.mbt` of the three library packages, `src/`,
  `src/zlib/` and `src/gzip/`, and of their internal packages
  `src/zlib/internal/adler32/`, `src/zlib/internal/header/`,
  `src/gzip/internal/crc32/` and `src/gzip/internal/header/`. The test-only
  package `src/internal/fixtures/` is not measured, nor is
  moonbit-community/flate, which the raw decoder holds.
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

The pitfalls the script pins (stale counters, `-f summary` skewing totals,
tcc on openSUSE) are described in zstd's ledger, `zstd/TEST_COVERAGE.md`.

Snapshot at the last full measurement (2026-10-21): **100.0 %** (360/360
lines).

## Policy

Must be covered by tests:

- every `raise` arm of the containers: each malformed header and trailer, each
  field cut short, each checksum wrong, built by hand
  (scripts/gen_deflate_vectors.mbtx writes them into each package's
  `vectors_wbtest.mbt`, with what zlib makes of each);
- every decision on header and trailer bytes, a pure function in
  `src/zlib/internal/header/` and `src/gzip/internal/header/`: checked over
  every pair of zlib header bytes against RFC 1950 written out separately, and
  over every value of each byte of a gzip header's start;
- the checksums, against bitwise references written from RFC 1950 and 1952,
  whole and in pieces, past Adler-32's reduction interval;
- what follows a stream or a member, under both `until` values;
- suspension on input and on output in every state, through byte-sized and
  random splits.

The raw DEFLATE decoding is the inflater's; its checks of RFC 1951 are held
to zlib's by the crafted streams and the seeded corruptions
(`src/reference_wbtest.mbt`), not by this ledger.

Accepted as uncovered (needs a row):

- defensive arms that are unreachable by construction;
- testable lines not yet tested, marked `not yet tested`.

Budgets are exact uncovered counts at the last measurement.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
