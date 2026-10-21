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
  `src/zlib/` and `src/gzip/`, and of their internal packages: the raw
  DEFLATE decoder `src/internal/inflate/` and encoder `src/internal/deflate/`,
  the copies of the shared parts `src/internal/huffman/` and
  `src/internal/lz77/` (generated from `parts/`, with their tests),
  `src/zlib/internal/adler32/`, `src/zlib/internal/header/`,
  `src/gzip/internal/crc32/` and `src/gzip/internal/header/`. The test-only
  package `src/internal/fixtures/` and the cross-check tool
  `src/internal/crosscheck/` are not measured.
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

The pitfalls the script pins (stale counters, `-f summary` skewing totals,
tcc on openSUSE) are described in zstd's ledger, `zstd/TEST_COVERAGE.md`.

Snapshot at the last full measurement (2026-10-21): **98.9 %** (1436/1452
lines), the sixteen uncovered lines ledgered below: seven of them are the
JS and Wasm GC variants of the match finders' reads, which native does not
compile.

## Policy

Must be covered by tests:

- every `raise` arm of the containers: each malformed header and trailer, each
  field cut short, each checksum wrong, built by hand
  (scripts/gen_deflate_vectors.mbtx writes them into each package's
  `vectors_wbtest.mbt`, with what zlib makes of each);
- every decision on header and trailer bytes, a pure function in
  `src/zlib/internal/header/` and `src/gzip/internal/header/`: checked over
  every pair of zlib header bytes against RFC 1950 written out separately, and
  over every value of each byte of a gzip header's start; the headers and
  trailers the encoders write, built by pure functions next to those that
  read them, are read back by them for every level and every combination of
  a gzip header's fields;
- the checksums, against bitwise references written from RFC 1950 and 1952,
  whole and in pieces, past Adler-32's reduction interval;
- what follows a stream or a member, under both `until` values;
- suspension on input and on output in every state, through byte-sized and
  random splits; for the encoders, that every split gives the same stream,
  that a flush makes the stream so far decode to the input so far, and that
  steps after the end take nothing;
- every check of RFC 1951 in the raw DEFLATE decoder, each held to zlib's
  answer, kind of error included, by the crafted streams and the seeded
  corruptions (`src/reference_wbtest.mbt`); its fast path, under the same
  streams given whole, with codes that encoders rarely write (distance codes
  of 15 bits with 13 extra bits, matches that run from a dictionary into the
  output) built bit by bit in `src/internal/inflate/inflater_wbtest.mbt`;
- the raw DEFLATE encoder: at every level, that every split of the input and
  of the output, with a dictionary and with flushes, gives the same stream;
  the SHA-256 of its streams at each level, which were libdeflate 1.24's own
  bytes for the same input when they were pinned (`src/encode_wbtest.mbt`);
  that a block ends when its sequences fill the store
  (`src/internal/deflate/deflater_wbtest.mbt`); the match finders against a
  search of every earlier position, and that they read nothing past the end
  they are given (`src/internal/lz77/`); the length-limited codes against
  optimal ones (`src/internal/huffman/code_maker_test.mbt`). Its streams
  are held to zlib's decoder, through Node, and to the `gzip` command, whole
  and cut after every flush, by `scripts/crosscheck.mbtx`.

Accepted as uncovered (needs a row):

- defensive arms that are unreachable by construction;
- lines that only an `abort` reaches, run by `panic` tests, whose counts the
  abort discards;
- testable lines not yet tested, marked `not yet tested`.

Budgets are exact uncovered counts at the last measurement.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
| src/internal/huffman/decode_table.mbt | 3 | The `abort`s of `Builder::Builder` (a root outside 1 to 15 bits, an alphabet past 4096 symbols) and of `Builder::build` (a table without room): the `panic` tests of `src/internal/huffman/decode_table_spec_test.mbt` run them, but the abort ends the test before its coverage counts are written. |
| src/internal/inflate/blocks.mbt | 1 | In `Inflater::run`, the `abort` for the fast path running out of input: unreachable by construction, since it runs only while the input holds the 8 bytes a unit can need. |
| src/internal/inflate/inflater.mbt | 1 | In `Inflater::step_with`, the `abort` for an unfinished unit that keeps more bytes than `stash` holds: unreachable by construction, since a unit needs at most 6 bytes beyond the bits held and keeps only those it fell short with. |
| src/gzip/encoder.mbt | 1 | In `Encoder::Encoder`, the `abort` for a header that cannot be written (`Header::is_writable`): the `panic` tests of `src/gzip/encode_wbtest.mbt` run it, for `Encoder` and `compress`, but the abort ends the test before its coverage counts are written. |
| src/internal/huffman/code_maker.mbt | 1 | The `abort` of `CodeMaker::CodeMaker` for an alphabet outside 2 to 1,024 symbols: the `panic` test of `src/internal/huffman/code_maker_test.mbt` runs it, but the abort ends the test before its coverage counts are written. |
| src/internal/deflate/deflater.mbt | 2 | In `Deflater::step`, the `abort` for an input buffer that is full with no block complete: unreachable by construction, since the buffer holds the window, a whole block and the look-ahead, and a block ends at 65,535 bytes. |
| src/internal/lz77/matchfinder.mbt | 7 | `load_u32`, `may_beat` and `extend_match` for JS and Wasm GC (`#cfg(not(any(target="native", target="wasm")))`), which read a byte at a time: the ledger measures native, which compiles the four-bytes-at-once ones instead. The gates run the same tests on JS and Wasm GC: the match finders' tests and the encoder's, including the SHA-256 of its output. |
