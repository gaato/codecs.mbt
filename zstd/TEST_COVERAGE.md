# Test coverage ledger

Line coverage of `gaato/zstd`, measured on native with `moon test
--enable-coverage` and reported in Coveralls-JSON mode. The rule is a closed
ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.sh` enforces this: a file with uncovered
> lines must have a row here whose budget is at least the actual count, and
> the script fails otherwise. Rows for fully covered files are flagged as
> stale and rows with slack are noted, so budgets only ever shrink.

## Running it

```fish
scripts/coverage_report.sh zstd                    # measure, print tables, check the ledger
scripts/coverage_report.sh zstd --from-json _build/coverage_report.zstd.json   # recheck only
```

CI runs it after the gates on every push and pull request. Exit status: 0 =
ledger OK, 1 = an unexplained or over-budget file, 2 = the run itself failed
(a failing test, a build error). The tests are deterministic: fixed vectors,
streams built byte by byte and bit by bit, and seeded pseudo-random splits
and corruptions.

### What is measured

- Sources: every non-test `.mbt` directly under `src/`, the library package,
  and under `src/internal/xxhash/`. The test-only checksum package under
  `src/internal/` is not measured.
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

Snapshot at the last full measurement (2026-10-19): **99.2 %** (508/512
lines).

## Policy

Must be covered by tests:

- every `raise` arm: each malformed-stream check has a stream built by hand
  that reaches it (`src/crafted_wbtest.mbt`);
- every block type, literals section type (raw, RLE, compressed, treeless;
  one and four streams; direct and FSE-compressed Huffman weights), table
  mode (predefined, RLE, FSE-compressed, repeat), repeat offset case, and
  frame header field size; several frames in a row and skippable frames;
- suspension on input and on output at every unit, through byte-sized and
  random splits.

Accepted as uncovered (needs a row):

- defensive arms that are unreachable by construction;
- testable lines not yet tested, marked `not yet tested`.

Budgets are exact uncovered counts at the last measurement.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
| src/fse.mbt | 2 | `Fse::build` returning false, and `Fse::read` raising on it: the spread of symbols over the table fills it exactly whenever the probabilities sum to the table size, and `Fse::read` only builds once they do (a probability never exceeds what remains: the largest value a field can hold is `remaining + 1`). RFC 8878 section 4.1.1 states the same guarantee. Kept because a table with unset rows could index past itself. |
| src/huffman.mbt | 1 | In `Huffman::build`, weights that overfill the table: each weight `w` takes `2^(w-1)` of `2^max_bits` entries, and the implied last weight completes the sum to exactly `2^max_bits`, so the ranges never run past the table. Kept because the fill would otherwise write past it. |
| src/sequences.mbt | 1 | In `reserve_window`, no room for a compressed block's bytes: a block is decoded only when no output is pending, it decodes to at most `block_max` bytes, and `block_max` is at most the window (`ring_max`), so `ensure_space` always succeeds. |
