# Test coverage ledger

Line coverage of `gaato/brotli`, measured on native with `moon test
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
moon run scripts/coverage_report.mbtx -- brotli   # measure, print tables, check the ledger
moon run scripts/coverage_report.mbtx -- brotli --from-json _build/coverage_report.brotli.json   # recheck only
```

The gates run it (`scripts/gates.mbtx`), on every push and pull request in
CI too. Exit status: 0 = ledger OK, 1 = a file whose uncovered lines differ
from its row (no row, more lines, fewer, or a row for a covered file), 2 = the
run itself failed
(a failing test, a build error). The tests are deterministic: fixed vectors,
streams built bit by bit, and seeded pseudo-random splits and corruptions.

### What is measured

- Sources: every non-test `.mbt` directly under `src/`, the library package;
  under `src/internal/blit/`, `src/internal/bits/`, `src/internal/huffman/`
  and `src/internal/lz77/`, the building blocks copied from `parts/` (the
  byte copy, the bit writer, prefix codes and decoding tables, the match finder), measured
  here through the tests copied with them, with the proof packages
  `src/internal/proof_bits/` and `src/internal/proof_codes/`; and under
  `src/internal/rules/`, `src/internal/prefix_code/` and
  `src/internal/transform/`, the decoder's pure
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

### HQ tests by target

All four targets check qualities 10 and 11 against SHA-256 pins from the
google/brotli 1.2.1 CLI in `src/reference_hq_vectors_wbtest.mbt`, in both
size-hint modes. The common inputs are at most 8,192 bytes: tiny and repeated
text, random and mixed bytes, UTF-8 dictionary text, and changing literal
alphabets, including windows 10 and 24. They keep the Float32/Double cost
model under byte-identity checks on every backend. Small vectors finish
their input in one call so window 24 uses a short forest rather than a
128 MiB streaming forest.

Every target also runs the reference command traces (tree and dictionary
matches), dictionary guards, distance coding, histogram-cap/tie-order and
context-map checks. The phase observer on 8,192 bytes asserts both actual
cost-pass counts and multiple blocks/clusters, as well as the memory bound.

The private native conformance package at
`../conformance/src/brotli_hq_native/` runs every original large
input/quality/window CLI pin, through 2,100,000 bytes, and the full window
matrix, in the workspace's regular native test phase. It is a separate
executable that Moon can schedule alongside the codec's tests. Large cases
check two encodes for every quality: whole-input `compress` with known size
against the named-file CLI pin, and unhinted split-input streaming against
the stdin CLI pin, even when those pins agree. This keeps both paths under
large-input checks, including block and 512 KiB read-schedule boundaries.
Hinted streaming versus `compress` equivalence remains checked by the small
cases on every target; the native streaming matrix also retains hint-mode
equality checks.
Coverage measures the codec's branch tests and common pins; the private
conformance matrix belongs to the regular test phase. This keeps large
byte-identity encodes from being repeated for line coverage while the exact
ledger still rejects any lost executable line.
Small tree layout, preparation, position-wrap and reset checks, the public
bound constants, and split-input streams at window 10 with correct, missing
and wrong hints, including flushes with a raw LZ77 dictionary, also run on
every target. The
streaming/hint/dictionary/reset matrix, full window-24 allocation and
growth checks, maximum parser capacities and archive-growth peak
regression in `src/reference_hq_wbtest.mbt` run on native only. These remain
part of native coverage; moving them does not relax any uncovered-line
budget.

Snapshot at the last full measurement (2026-11-18): **96.9 %** (3973/4098
lines); the 125 uncovered lines are ledgered below, most of them the Wasm, JS and
Wasm GC variants that native does not compile.

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
- LZ77 dictionaries: `brotli -D`'s streams at every quality and window
  (`brotli/scripts/gen_dict_vectors.mbtx`), copies from the dictionary into
  output slices down to one byte and once the ring is full, a copy past the
  dictionary's end or the meta-block's refused, and the encoder's matches
  into the dictionary, shared between encoders and the same under every
  split (`src/dictionary_lz77_wbtest.mbt`);
- the `gaato/codec_bytes` trait implementations, through generic code in
  `src/api_test.mbt`;
- every encoder path: simple prefix codes of one to four symbols, complex
  codes (including a code length code of one symbol), the uncompressed
  fallback, flushes, the input buffer sliding, and suspension on output
  through byte-sized and random splits. The encoder's streams are held to
  google/brotli's decoder by `scripts/crosscheck.mbtx`, which CI runs.
- HQ parser scratch during actual parsing, including q11 archive growth and
  both cost passes, and q10's literal-estimator scratch. The phase observer
  checks actual capacities against the parser bound separately from coding;
  a dominant coding bound cannot mask omitted parser allocations.
- Qualities 0..3: 120 pinned CLI digests in the native identity matrix and
  64 small digests on JS, Wasm and Wasm GC. Branch, split, flush, dictionary,
  reset and allocation checks run on all targets; the large fragment and
  distant-match matrices run only on native to keep portable CI tests cheap.

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
| --- | --- | --- |
| src/reference_low_bits.mbt | 1 | The six-nibble fragment header needs more than 1 MiB of input. The CLI-compatible scheduler caps each q0/q1 fragment at 512 KiB, including raw fallback. Four- and five-nibble headers, length patches, fallback and bit offsets are covered by the low-quality CLI pins and streaming tests. |
| src/reference_low_encoder.mbt | 1 | The no-input, no-action guard in `quick_process`: the fixed-read scheduler calls only with a nonempty input block or `Flush`/`Finish`. The low-quality tests cover empty and repeated flushes, empty finish, random splits, reset and both hint modes. |
| src/decoder.mbt | 2 | In `next_aligned_byte`, loading a byte from `stash`, and in `compact_stash`, shifting a nonempty suffix after consuming a prefix. The stash holds the bytes of a unit that ran out of input. Completing that unit consumes those bytes before the byte-aligned loops start. The compaction loop preserves the suffix if one is ever present. |
| src/meta_block_writer.mbt | 1 | The `cached_match_prefix` fallback for JS and Wasm GC returns true, leaving prefix comparison to their match-length routine. Native and Wasm compile the four-byte rejection instead. The same quality-4 SHA-256 pins run on all four targets. |
| src/meta_block_writer_wasm.mbt | 45 | The Wasm quality-4 payload loop uses the parser's fixed command and alphabet limits to omit repeated range checks, pairs literal codes (at most 30 bits) and skips zero-width extras. Native compiles the standard loop; GC/JS use paired codes with checked command accesses. The quality-4 SHA-256 pins, split and output-budget tests run on all four targets. |
| src/meta_block_writer_portable.mbt | 35 | The GC/JS quality-4 writer pairs literal codes and skips zero-bit command extras. Native compiles the standard loop and Wasm its unchecked command-table loop. The unchanged quality-4 SHA-256 pins run on GC and JS, including flushes and windows 10..24; the gates also run the split and output-budget tests there. |
| src/internal/bits/bit_packer.mbt | 10 | `BitPacker::write`, `BitPacker::write_fitting` and `BitPacker::flush` for JS (`#cfg(target="js")`), the 32-bit accumulator moved a byte at a time: the ledger measures native, which compiles the 64-bit `write` and the eight-byte `flush` instead. The gates run the same tests on JS: `src/internal/bits/bit_packer_test.mbt` and the encoder's, including the SHA-256 of its output. |
| src/internal/blit/blit.mbt | 10 | `bytes`, `into_view`, `move_down` and `from_view` for JS (`#cfg(target="js")`), forward loops without index checks, and `forward` for JS and Wasm GC, a byte at a time where native and Wasm copy eight: the ledger measures native, which compiles the block copies and the eight-byte steps instead. The gates run the same tests on JS: `src/internal/blit/blit_test.mbt` and the decoder's tests, which write through both. |
| src/internal/huffman/decode_table.mbt | 3 | The `abort`s of `Builder::Builder` (a root outside 1 to 15 bits, an alphabet past 4096 symbols) and of `Builder::build` (a table without room): the `panic` tests of `src/internal/huffman/decode_table_spec_test.mbt` run them, but the abort ends the test before its coverage counts are written. |
| src/commands.mbt | 19 | The MSB6 context in `fast_literals` needs a longer test stream than "abb" in `src/crafted_wbtest.mbt`. The Wasm-only unchecked command tables and inline context and prefix-code reader are inactive in the native coverage run. The Wasm suite exercises them with the decoder's split, malformed-input and reference-vector tests. |
| src/lz77_dictionary.mbt | 2 | The `abort` of `dictionary_copy` without a dictionary: the decoder enters it only from `distance`, which takes the dictionary's branch only when there is one. And in `dictionary_match`, the stop at a candidate past the furthest distance a stream can code (67,108,860 bytes counting the window's reach): the index holds only the dictionary's last 67,108,860 bytes, so a candidate is that far back only with a dictionary near that size and input as far into the stream, whose index alone would take over 300 MiB, more than the tests allocate. The check subtracts before it compares, so that the sum it stands for cannot overflow; the crosscheck's dictionary streams decode with `brotli -d -D`. |
| src/internal/huffman/code_maker.mbt | 1 | The `abort` of `CodeMaker::CodeMaker` for an alphabet outside 2 to 1,024 symbols: the `panic` test of `src/internal/huffman/code_maker_test.mbt` runs it, but the abort ends the test before its coverage counts are written. |
| src/internal/lz77/hash.mbt | 4 | The byte-wise `load4` for JS and Wasm GC is excluded by native's cfg. The hash tests and the encoder's SHA-256 pins run on both targets. |
| src/internal/match_length_fast/length.mbt | 3 | The unchecked byte-wise `length` for JS and Wasm GC is excluded by native's cfg. The package's alignment, exact-end, mismatch and overlap tests run on all four targets. |
| src/reference_encoder.mbt | 2 | `ref_process`'s no-input, no-action guard: its scheduler calls only with a nonempty input block or `Flush`/`Finish`. And the dictionary-search stop past 67,108,860 coded distance bytes, which requires a large dictionary index as described for `src/lz77_dictionary.mbt`; the same static-dictionary distance cap is tested directly in "reference helpers: position wraps, capped distances and ring-edge matches". |
| src/reference_hq_dp.mbt | 10 | The Wasm GC calls to the copy-code, command-symbol and node-update helpers in both inner loops, including the body of `HqDp::set`. Native expands those helpers in the loops. The HQ tests run the same reference digests on both targets. |
| src/reference_hq_parse.mbt | 1 | The raw-dictionary search stop past 67,108,860 coded distance bytes needs the large dictionary index described for `src/lz77_dictionary.mbt`, exceeding the test allocation budget. HQ dictionary streams are checked with the CLI decoder; the maximum coded distance is also exercised directly in the HQ distance-parameter test. |
| src/reference_hq_process.mbt | 1 | The no-input, no-action guard: the fixed-read scheduler calls only with a nonempty input block or `Flush`/`Finish`. The HQ streaming tests cover those calls, empty streams, reset and both hint modes. |
| src/reference_hasher.mbt | 11 | The JS/Wasm GC checked probe, table access, scalar match and UInt32 helpers are excluded by the native target. The native/Wasm SIMD match returns the full limit when the candidate is the current position, preserving the scalar result if a bucket or chain holds that position. All targets run the reference digest pins and the wrap and ring-edge tests. |
| src/internal/whole/whole.mbt | 4 | The output reaching 2^31 - 1 bytes with no `max_output` (`None => MAX_LENGTH` in `decode`, the `abort` of `encode`), which no test can allocate, and `copy` for JS (`#cfg(target="js")`), a loop without index checks: the ledger measures native, which compiles the block copy instead. The gates run the same tests on JS: `src/internal/whole/whole_test.mbt`, and every `compress` and `decompress` test of the module. |
