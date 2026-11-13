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
  tool under `src/internal/` are not measured. The shared `seqcases`
  fixture generator is measured alongside `match` and `seqenc`, so every
  new internal package is included apart from those existing tool exclusions.
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

Snapshot at the last full measurement (2026-11-13): **96.9 %**
(2011/2075 lines); the remaining 64 lines include 50 checked-target lines
that native does not compile, alongside the existing 14 lines. Every line
is listed with its reason below.

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

Sequence encoding additionally covers every line of `src/internal/match` and
`src/internal/seqenc`: independently executed repeat histories, every
selected mode (asserted snapshots), rejection of invalid repeated tables,
1/2/3-byte sequence counts including 32,512 sequences, long LL/ML extras,
31-bit OF packing at every bit alignment (also on JS), and a distance of
window minus one. `src/internal/seqcases` supplies crafted frames to both
`src/sequence_encode_wbtest.mbt` and the external crosscheck tool. Fast's
small-window test wraps forty times and reconstructs its matches before
reset. The existing split/flush/reset and conformance tests now exercise
real matches; Huffman and Treeless literals include persistence across raw
and RLE blocks. No new uncovered-line allowance was added.

Double-fast adds independent sequence reconstruction over forty small
window wraps; exact-window and invalid-candidate checks; a deliberately
colliding short candidate which loses to the eight-byte long table; a
repeat-first assertion; every short hash width; empty and tiny blocks.
The full-window memory test reaches both level-four tables plus a 2 MiB
window and a block, and checks effective parameter selection across all
levels and size classes. The shared harness and one-byte split tests run
levels 3 and 4 as well as the existing levels. External crosscheck adds
level-four frames, flushes, bytewise input and distant cross-block
prefixes. No additional uncovered-line allowance is needed.

Hash-chain tests cover greedy/lazy/lazy2 depth, a later match beating the
greedy choice, repeat-one priority and immediate repeat-two swapping,
searchLog attempt limits, overwritten chain links, exact-window and
too-old candidates, invalid initial repeats, empty/tiny blocks, minMatch
3..6 hash selection, and forty small-window wraps with a ring bias.
Sequences are reconstructed byte by byte using independent RFC repeat
transitions, retaining the full frame outside the matcher. The additional
double-fast rebase fixture uses 1,024 seeded random bytes, 64 unrelated
bytes, and separate replays of [0:64] and [100:164]; it checks invalidated
entries and the hash identity of every surviving position, then executes
all sequences independently. Separate replays keep the retained range's
distance eligible rather than expiring it with the other replay first.
Every effective parameter row pins all six numbers and the strategy.

Round trips, reset and cross-target SHA-256 snapshots cover all twelve
levels. The shared harness includes levels 5, 6, 7, 8, 9, 10, 11 and 12,
with one-byte splits on small inputs, known/unknown sizes, checksums and
flushes. External crosscheck emits all twelve levels, plus greedy/lazy/
lazy2 flushes, bytewise input and distant prefixes. The maximum-memory
test reaches a 4 MiB retained window, one block, 2^22 chain links and
2^23 hash heads. Hash-chain code has full line coverage; no additional
uncovered-line allowance is needed.

Known-size parameter tests pin the adjusted window/chain/hash rows at ten
sizes for all twelve levels and check that table sizes and the derived
memory bound only shrink through every size-class boundary. Fast matching
now pins every (LL, ML, distance) by a fingerprint against instrumented
v1.5.7 reference output over a deterministic collision/repetition input,
for all four hash widths and targetLength 0/8. It also checks that search
disables repeats outside the retained prefix without changing committed
history. These cover the paired-search schedule and insertion ordering.

The shared `repeat-fse` and `repeat-rle` fixtures now insert raw, RLE and
zero-sequence compressed blocks between each sequence-bearing block.
Tests parse their actual block headers, sequence counts and table modes,
and require Repeat after those boundaries. A separate shared fixture
establishes [10, 1, 4] with LL=64, ML=64, distance=10, crosses all three
boundaries, then encodes LL=0 with Offset_Value=3. Tests check the retained
decoder history after every block, the final distance 9 and history
[9, 10, 1], and the actual OF symbol (an erroneous reset would resolve to
distance 0). All three fixtures are also decoded by `zstd -d` and Node in
the external crosscheck. No uncovered-line budget was added.

Accepted as uncovered (needs a row):

- defensive arms that are unreachable by construction;
- testable lines not yet tested, marked `not yet tested`.

Budgets are exact uncovered counts at the last measurement.

Wide matcher reads add independent checked hash comparisons at every
alignment for widths 4..8, exact-end match lengths and every mismatch
position through 65 bytes, and overlapping matches at distances 1..16.
The separate SIMD package compares its result with checked bytes on all
four targets. The shared boundary inputs cover lengths 1..48 and tails
1..16 at 1 KiB and 128 KiB, with matches of 7/8/9, 15/16/17 and 31/32/33
bytes. At levels 1, 3, 5 and 12, gaato decodes both sized and unsized
frames, checks input splitting, and verifies SHA-256 pins established
before changing the checked implementation. No existing pin was changed.
Small-window frames from fast, double-fast and both lazy depths complete
tail hashes across blocks, slide a 1 KiB window and replay evicted or
surviving ranges; gaato and both external decoders read these same frames.
The independent sequence replay fixture also checks eviction for all three
finders. XXH64 tests every length 1..96 at all sixteen alignments and
incremental splits around 8/16/32-byte boundaries. Every compiled native
line of the new paths is covered; the added budgets name only the checked
JS/Wasm GC alternatives that the native coverage run cannot compile.

## Accepted uncovered

The encoder and all three finders share one history buffer. Tests fill its
window, slack and block capacity, check both tables at the physical cut,
and replay bytes just above and below six successive cuts for fast,
double-fast and both lazy depths. A 12 MiB mixed production input has
SHA-256 pins established with the original per-block sliding code; levels
1, 3, 5 and 12 decode it and preserve those bytes on every target. The
external corpus includes the same input and repeated small-window cycles.
Input splitting with identical flush positions is compared at all levels.
No uncovered-line budget is added for shared history.

| File | Budget | Reason |
| --- | --- | --- |
| src/internal/match/access.mbt | 5 | Checked `read`, `write`, `match_length` and `may_beat` for JS/Wasm GC, excluded by native's cfg. The gates run the same matcher tests and unchanged SHA-256 pins on both checked targets. |
| src/internal/match/fast.mbt | 12 | Original JS/Wasm GC construction and byte-wise hash, excluded by native's cfg. The gates run the boundary round trips, width fingerprints and unchanged SHA-256 pins there. |
| src/internal/match/dfast.mbt | 15 | Original JS/Wasm GC construction, byte-wise hashes and their wrappers, excluded by native's cfg. The gates run all widths, rebase fixtures, boundary round trips and unchanged SHA-256 pins there. |
| src/internal/match/lazy.mbt | 11 | Original JS/Wasm GC construction and byte-wise hash, excluded by native's cfg. The gates run all depths, ring limits, boundary round trips and unchanged SHA-256 pins there. |
| src/internal/match_length_fast/length.mbt | 2 | Checked JS/Wasm GC reference, excluded by native's cfg. The package's alignment, exact-end, mismatch and overlap tests run on all four targets. |
| src/internal/xxhash/xxhash.mbt | 5 | Checked JS/Wasm GC read32/read64, excluded by native's cfg. The gates run the reference digests, incremental splits and exact-end/unaligned tests on both targets. |
| src/fse.mbt | 1 | `Fse::read` raising when `Fse::build` returns false: the spread of symbols over the table (`@fse.spread`) fills it exactly whenever the probabilities sum to the table size, and `Fse::read` only builds once they do (a probability never exceeds what remains: the largest value a field can hold is `remaining + 1`). RFC 8878 section 4.1.1 states the same guarantee. Kept because a table with unset rows could index past itself. `src/internal/fse/fse_test.mbt` checks that `spread` reports a distribution that does not fill the table. |
| src/huffman.mbt | 1 | In `Huffman::build`, the message for weights that overfill the table, which `@huffman.build_table` never reports: see the next row. |
| src/internal/bits/bit_packer.mbt | 8 | `BitPacker::write` and `BitPacker::write_fitting` for JS (`#cfg(target="js")`), the 32-bit accumulator: the ledger measures native, which compiles the 64-bit `write` instead. The gates run the same tests on JS: `src/internal/bits/bit_packer_test.mbt` and the encoder's round trips. |
| src/internal/huffman/table.mbt | 2 | In `fill`, the check for weights that overfill the table and its OVERFULL: each weight `w` takes `2^(w-1)` of `2^max_bits` entries, and the implied last weight completes the sum to exactly `2^max_bits`, so the blocks never run past the table. `moon prove` proves it (PROOFS.md: `build_table` never returns OVERFULL). Kept because the reference decoder checks it. |
| src/internal/huffman_code/code_maker.mbt | 1 | The `abort` of `CodeMaker::CodeMaker` for an alphabet outside 2 to 1,024 symbols: the `panic` test of `src/internal/huffman_code/code_maker_test.mbt` runs it, but the abort ends the test before its coverage counts are written. |
| src/sequences.mbt | 1 | In `reserve_window`, no room for a compressed block's bytes: a block is decoded only when no output is pending, it decodes to at most `block_max` bytes, and `block_max` is at most the window (`ring_max`), so `ensure_space` always succeeds. |
