# Test coverage ledger

Line coverage of `gaato/brotli`, measured on native with `moon test
--enable-coverage` and reported in Coveralls-JSON mode. The rule is a closed
ledger:

> **Every uncovered line is either covered by a test or listed below with a
> reason.** `scripts/coverage_report.mbtx` enforces this: a file with uncovered
> lines must have a row here whose budget is at least the actual count, and
> the script fails otherwise. Rows for fully covered files are flagged as
> stale and rows with slack are noted, so budgets only ever shrink.

## Running it

```sh
moon run scripts/coverage_report.mbtx -- brotli   # measure, print tables, check the ledger
moon run scripts/coverage_report.mbtx -- brotli --from-json _build/coverage_report.brotli.json   # recheck only
```

CI runs it after the gates on every push and pull request. Exit status: 0 =
ledger OK, 1 = an unexplained or over-budget file, 2 = the run itself failed
(a failing test, a build error). The tests are deterministic: fixed vectors,
streams built bit by bit, and seeded pseudo-random splits and corruptions.

### What is measured

- Sources: every non-test `.mbt` directly under `src/`, the library package;
  under `src/internal/blit/`, `src/internal/bits/`, `src/internal/huffman/`
  and `src/internal/lz77/`, the building blocks copied from `parts/` (the
  byte copy, the bit writer, prefix codes and decoding tables, the match finder), measured
  here through the tests copied with them, with the proof packages
  `src/internal/proof_bits/` and `src/internal/proof_codes/`; and under
  `src/internal/rules/` and `src/internal/transform/`, the decoder's pure
  functions of the values it has read and its dictionary word transforms. The test-only
  checksum package and the crosscheck tool under `src/internal/` are not
  measured.
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

Snapshot at the last full measurement (2026-10-21): **98.7 %** (929/941
lines).

## Policy

Must be covered by tests:

- every `raise` arm: each malformed-stream check has a stream built bit by
  bit that reaches it (`src/crafted_wbtest.mbt`);
- every state of the decoder and every RFC 7932 feature: block switches of
  each kind, all four literal context modes, direct and postfix distance
  codes, dictionary references, uncompressed and metadata meta-blocks;
- suspension on input and on output at every unit, through byte-sized and
  random splits;
- both ways of ending a stream: `EndOfInput` (trailing bytes, `Done` only
  with `end`) and `EndOfMember` (stopping before what follows);
- the `gaato/codec_bytes` trait implementations, through generic code in
  `src/api_test.mbt`;
- every encoder path: simple prefix codes of one to four symbols, complex
  codes (including a code length code of one symbol), the uncompressed
  fallback, flushes, the input buffer sliding, and suspension on output
  through byte-sized and random splits. The encoder's streams are held to
  google/brotli's decoder by `scripts/crosscheck.mbtx`, which CI runs.

Accepted as uncovered (needs a row):

- defensive arms that are unreachable by construction;
- aborts that `panic` tests reach, whose counts the abort loses;
- code compiled only for another target, which the gates test there;
- testable lines not yet tested, marked `not yet tested`.

Budgets are exact uncovered counts at the last measurement.

## Accepted uncovered

| File | Budget | Reason |
| --- | --- | --- |
| src/decoder.mbt | 1 | In `next_aligned_byte`, loading a byte from `stash`: uncompressed and metadata bytes would come from it only if `stash` held bytes there, and it never does. A unit leaves bytes in `stash` only when they fall short of what it needs, so when it completes it has consumed them all; the byte-aligned loops start after that unit. |
| src/internal/bits/bit_packer.mbt | 10 | `BitPacker::write`, `BitPacker::write_fitting` and `BitPacker::flush` for JS (`#cfg(target="js")`), the 32-bit accumulator moved a byte at a time: the ledger measures native, which compiles the 64-bit `write` and the eight-byte `flush` instead. The gates run the same tests on JS: `src/internal/bits/bit_packer_test.mbt` and the encoder's, including the SHA-256 of its output. |
| src/internal/blit/blit.mbt | 4 | `bytes` and `into_view` for JS (`#cfg(target="js")`), forward loops without index checks: the ledger measures native, which compiles the block copies instead. The gates run the same tests on JS: `src/internal/blit/blit_test.mbt` and the decoder's tests, which write through both. |
| src/internal/huffman/decode_table.mbt | 3 | The `abort`s of `Builder::Builder` (a root outside 1 to 15 bits, an alphabet past 4096 symbols) and of `Builder::build` (a table without room): the `panic` tests of `src/internal/huffman/decode_table_spec_test.mbt` run them, but the abort ends the test before its coverage counts are written. |
| src/commands.mbt | 4 | In `fast_literals`, the MSB6 context (`p1 >> 2`): the one test stream with MSB6 (`src/crafted_wbtest.mbt`, "abb") is too short for the fast path, which needs two input bytes left; the slow path's `literal_context` computes the same expression and that test covers it. And `copy_overlapping` for JS and Wasm GC, a byte at a time, excluded by native's cfg; the gates run the decoder's tests and vectors there. And Wasm's `fast_commands_pay`, which turns the fast command loop off there, excluded the same way; on Wasm the decoder's tests and vectors run through the slow path. |
| src/internal/lz77/hash.mbt | 6 | `load4`, `read` and `write` for JS and Wasm GC (`#cfg(not(any(target="native", target="wasm")))`), which read a byte at a time and check every index: the ledger measures native, which compiles the one-load and unchecked ones instead. The gates run the same tests on JS and Wasm GC: the match finders' tests and the encoder's, including the SHA-256 of its output. |
| src/internal/match_length_fast/length.mbt | 2 | The checked JS/Wasm GC `length`, excluded by native's cfg. The package's alignment, exact-end, mismatch and overlap tests run on all four targets. |
