# Test coverage ledger

Line coverage of `gaato/png`, measured on native with `moon test
--enable-coverage` and reported in Coveralls-JSON mode. The rule is a closed
ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.mbtx` enforces this: a file with uncovered
> lines must have a row here whose budget is exactly the actual count, and
> the script fails otherwise, for a row with a larger budget and for one of a
> fully covered file as well: a budget with room to spare would let a line
> that tests stop reaching go unnoticed.

## Running it

```sh
moon run scripts/coverage_report.mbtx -- png   # measure, print tables, check the ledger
moon run scripts/coverage_report.mbtx -- png --from-json _build/coverage_report.png.json   # recheck only
```

The gates run it (`scripts/gates.mbtx`), on every push and pull request in
CI too. Exit status: 0 = ledger OK, 1 = a file whose uncovered lines differ
from its row (no row, more lines, fewer, or a row for a covered file), 2 = the
run itself failed
(a failing test, a build error).

### What is measured

- Sources: every non-test `.mbt` of the package `src/` (the decoder's state
  machine, the fixed-length ancillary chunks, the blocks of reported ones,
  APNG's frames, `decode`, the conversions and `scatter`), of its internal
  packages `src/internal/rules/` (chunk types and their order, IHDR's
  fields, row sizes, Adam7's passes, fcTL's rectangle),
  `src/internal/filter/` (the filters' reverse and its bridges),
  `src/internal/filter_fast/` (the decoder's faster Up filter),
  `src/internal/convert/` (a sample's arithmetic) and `src/internal/sizes/`
  (a row's bytes and a frame's rectangle, proved), and of the copies of the shared parts
  `src/internal/blit/`, `src/internal/crc32/` and `src/internal/proof_bits/` (generated from
  `parts/`, with their tests).
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

The pitfalls the script pins (stale counters, `-f summary` skewing totals,
tcc on openSUSE) are described in zstd's ledger, `zstd/TEST_COVERAGE.md`.

Snapshot at the last full measurement (2026-11-15): **98.1 %** (1044/1064
lines); the 20 uncovered lines are ledgered below, all of them the JS and Wasm
GC variants that native does not compile.

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
every frame against the png crate's. Outside the gates,
[`docs/robustness.md`](https://github.com/gaato/codecs.mbt/blob/main/png/docs/robustness.md) records a run over corpora of
broken files from typst, image-png and libspng.

Accepted as uncovered (needs a row):

- defensive arms that are unreachable by construction;
- lines that only an `abort` reaches, run by `panic` tests, whose counts the
  abort discards;
- code compiled only for another target (JS, Wasm GC), which the gates test
  there;
- testable lines not yet tested, marked `not yet tested`.

Budgets are the exact uncovered counts: the script fails on any difference.

## Accepted uncovered

| File | Budget | Reason |
|---|---|---|
| src/internal/blit/blit.mbt | 6 | `bytes` and `into_view` for JS (`#cfg(target="js")`), forward loops without index checks, and `forward` for JS and Wasm GC, a byte at a time where native and Wasm copy eight: the ledger measures native, which compiles the block copies and the eight-byte steps instead. The gates run the same tests on JS: `src/internal/blit/blit_test.mbt`, and the decoder's, among them "step_into writes what step writes, into a whole array". |
| src/internal/crc32/crc32.mbt | 13 | `update_bytes` for JS and Wasm GC (`#cfg(not(any(target="native", target="wasm")))`), which assembles bytes in the caller's loop to preserve those backends' performance. Native compiles the word-load variant instead. The same `crc32_test.mbt` runs on JS and Wasm GC, checking the bitwise reference, offsets 0 to 7, lengths 0 to 64, and CRC continuation across every tested split. |
| src/internal/filter_fast/filter_fast.mbt | 1 | `unfilter` for JS and Wasm GC (`#cfg(not(any(target="native", target="wasm")))`), which calls `@filter.unfilter`: the ledger measures native, which compiles the SIMD one instead. The gates run the package's tests, which compare it with `@filter.unfilter`, on JS and Wasm GC too. |
