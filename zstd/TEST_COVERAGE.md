# Test coverage ledger

Line coverage of `gaato/zstd`, measured on native with `moon test
--enable-coverage` and reported in Coveralls-JSON mode. The rule is a closed
ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.mbtx` enforces this: a file with uncovered
> lines must have a row here whose budget is at least the actual count, and
> the script fails otherwise. Rows for fully covered files are flagged as
> stale and rows with slack are noted, so budgets only ever shrink.

## Running it

```sh
moon run scripts/coverage_report.mbtx -- zstd   # measure, print tables, check the ledger
moon run scripts/coverage_report.mbtx -- zstd --from-json _build/coverage_report.zstd.json   # recheck only
```

CI runs it after the gates on every push and pull request. Exit status: 0 =
ledger OK, 1 = an unexplained or over-budget file, 2 = the run itself failed
(a failing test, a build error). The tests are deterministic: fixed vectors,
streams built byte by byte and bit by bit, and seeded pseudo-random splits
and corruptions.

### What is measured

- Sources: every non-test `.mbt` directly under `src/`, the library package
  (the decoder and the encoder), and under the internal packages it ships (`src/internal/header/`,
  `src/internal/frame/`, `src/internal/huffman/`, `src/internal/xxhash/`,
  the encoder's `src/internal/fse/` and `src/internal/huffenc/`, the copies
  of `parts/` in `src/internal/bits/` and `src/internal/huffman_code/`, and
  the proof packages). The test-only checksum package and the crosscheck
  tool under `src/internal/` are not measured.
- Counts are Coveralls lines: lines with at least one instrumented point,
  covered when any point on them ran.

### Pitfalls the script pins

- Counters from earlier runs and trace maps of moved or deleted packages
  silently corrupt the merge, so every run deletes `_build/**/moonbit_coverage_*`
  and `_build/native/debug/test` first, and passes the trace maps and counter
  files to the reporter explicitly.
- `-f summary` omits fully covered files, which skews totals; the script uses
  the Coveralls JSON.
- moon's bundled tcc cannot link on some hosts (openSUSE); the script sets
  `MOON_CC=cc` unless it is already set.

Snapshot at the last full measurement (2026-11-13): **99.0 %** (1351/1365
lines).

## Policy

Must be covered by tests:

- every `raise` arm: each malformed-stream check has a stream built by hand
  that reaches it (`src/crafted_wbtest.mbt`);
- every decision on header bytes the decoder holds (frame, block and
  literals section headers, the jump table), a pure function in
  `src/internal/header/`: checked against a reference written from RFC 8878
  over its whole input space where it is small enough (every block header
  on native, every frame header descriptor and window descriptor) and a
  grid and seeded random inputs elsewhere;
- the tables `Fse::build` and `Huffman::build` fill in place: equal to
  references written from RFC 8878 sections 4.1.1 and 4.2.1, for the
  predefined distributions, every table the test vectors build, and seeded
  random distributions and weights (`src/fse_spec_wbtest.mbt`,
  `src/huffman_spec_wbtest.mbt`, `src/spec_vectors_wbtest.mbt`);
- every block type, literals section type (raw, RLE, compressed, treeless;
  one and four streams; direct and FSE-compressed Huffman weights), table
  mode (predefined, RLE, FSE-compressed, repeat), repeat offset case, and
  frame header field size; several frames in a row and skippable frames;
- suspension on input and on output at every unit, through byte-sized and
  random splits;
- the encoder's entropy coders, through the decoder's own readers: FSE table
  descriptions read back by `Fse::read` into the table `Fse::build` makes,
  for every distribution of up to three symbols over 32 states and seeded
  random ones at every accuracy log, and FSE streams decoded to the symbols
  encoded with every bit used (`src/fse_encode_wbtest.mbt`); Huffman tree
  descriptions, direct and FSE-compressed, read back by `Huffman::read`, and
  literals in one and four streams decoded by `Huffman::decode`
  (`src/huffman_encode_wbtest.mbt`); `normalize` over every histogram of
  three symbols of up to 12 and seeded random ones, and `settle` over
  arbitrary shares (`src/internal/fse/`).

Accepted as uncovered (needs a row):

- defensive arms that are unreachable by construction;
- testable lines not yet tested, marked `not yet tested`.

Budgets are exact uncovered counts at the last measurement.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
| src/fse.mbt | 1 | `Fse::read` raising when `Fse::build` returns false: the spread of symbols over the table (`@fse.spread`) fills it exactly whenever the probabilities sum to the table size, and `Fse::read` only builds once they do (a probability never exceeds what remains: the largest value a field can hold is `remaining + 1`). RFC 8878 section 4.1.1 states the same guarantee. Kept because a table with unset rows could index past itself. `src/internal/fse/fse_test.mbt` checks that `spread` reports a distribution that does not fill the table. |
| src/huffman.mbt | 1 | In `Huffman::build`, the message for weights that overfill the table, which `@huffman.build_table` never reports: see the next row. |
| src/internal/bits/bit_packer.mbt | 8 | `BitPacker::write` and `BitPacker::write_fitting` for JS (`#cfg(target="js")`), the 32-bit accumulator: the ledger measures native, which compiles the 64-bit `write` instead. The gates run the same tests on JS: `src/internal/bits/bit_packer_test.mbt` and the encoder's round trips. |
| src/internal/huffman/table.mbt | 2 | In `fill`, the check for weights that overfill the table and its OVERFULL: each weight `w` takes `2^(w-1)` of `2^max_bits` entries, and the implied last weight completes the sum to exactly `2^max_bits`, so the blocks never run past the table. `moon prove` proves it (PROOFS.md: `build_table` never returns OVERFULL). Kept because the reference decoder checks it. |
| src/internal/huffman_code/code_maker.mbt | 1 | The `abort` of `CodeMaker::CodeMaker` for an alphabet outside 2 to 1,024 symbols: the `panic` test of `src/internal/huffman_code/code_maker_test.mbt` runs it, but the abort ends the test before its coverage counts are written. |
| src/sequences.mbt | 1 | In `reserve_window`, no room for a compressed block's bytes: a block is decoded only when no output is pending, it decodes to at most `block_max` bytes, and `block_max` is at most the window (`ring_max`), so `ensure_space` always succeeds. |
