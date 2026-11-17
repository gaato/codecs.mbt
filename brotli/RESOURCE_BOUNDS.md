# Resource bounds

What a decoder and an encoder hold, and what keeps each structure from growing without
limit. The rule: **every structure that grows with the input is listed here
with its bound**. A new one needs a row before it ships.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests. A test counts only if it drives the structure to its limit, or checks
the bound after every step over streams that push it. `scripts/bounds_check.mbtx`,
run by `scripts/gates.mbtx`, enforces the naming; whether a named test really
reaches the bound is checked in review. The other tables are prose.

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|
| Sliding window (`src/decoder.mbt`, `ring`) | At most `1 << WBITS` bytes, so at most 16 MiB (WBITS 24); allocated from 1 KiB, doubling only as output needs it. A stream declaring a window (`(1 << WBITS) - 16` bytes, RFC 7932 section 9.1) over the one `max_window_bits` allows (24 by default, clamped to 10..24) is refused before anything is allocated; large-window streams (Shared Brotli, RFC 9841, not implemented) are refused | `LimitExceeded` with resource `Memory`, `needed` the stream's window and `limit` the largest allowed, both as `(1 << WBITS) - 16`; `Corrupt` for large-window streams | `src/bounds_wbtest.mbt`: "the window is at most 1 << WBITS and grows only with output", "output slices, the stash and the tables stay within their bounds"; `src/decode_wbtest.mbt`: "max_window_bits refuses larger windows and is clamped"; `src/crafted_wbtest.mbt`: "malformed streams raise the error the RFC calls for" |
| Output slice (`Decoder::step`, `Decoder::step_into`) | At most the caller's buffer per step, down to 1 byte; the rest waits in the window | `NeedMoreOutput` | `src/bounds_wbtest.mbt`: "output slices, the stash and the tables stay within their bounds"; `src/decode_wbtest.mbt`: "any fixed input split and output size give the same output" |
| Unfinished unit (`src/decoder.mbt`, `stash`) | 8 bytes: the longest unit, a command, is 63 bits. Every other input byte is decoded or reported unconsumed | Cannot overflow: a unit that has its bytes completes | `src/bounds_wbtest.mbt`: "output slices, the stash and the tables stay within their bounds"; `src/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| Prefix code tables (`src/huffman.mbt`, `Group`, built by `Builder` of `src/internal/huffman`) | Per tree, alphabet + 376 entries of 2 bytes (the reference decoder's bound). Per meta-block at most 256 literal trees (632 entries each), 256 insert-and-copy trees (1,080) and 256 distance trees (896 at most): 1.3 MiB in the worst case, allocated for the trees a meta-block declares and kept for the next | Cannot overflow: RFC 7932 caps tree counts and alphabets | `src/bounds_wbtest.mbt`: "output slices, the stash and the tables stay within their bounds"; `src/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| LZ77 dictionary (`src/decoder.mbt`, `dictionary`) | The caller's bytes, held by reference and not copied; a copy from it reads them there, and never past their end | A distance more than the dictionary's length past the window's reach names a static word, checked as before; a copy past the dictionary's end is `Corrupt` | `src/dictionary_lz77_wbtest.mbt`: "lz77_address: the dictionary from its end, static words after it", "brotli -D streams decode with the dictionary, however split" |
| Dictionary index (`src/lz77_dictionary.mbt`, `DictionaryIndex`, held by the `Dictionary`) | A copy of the dictionary's last 64 MiB at most (67,108,860 bytes, the furthest a distance reaches), a head table of 256 to 2^17 entries and one link per byte of that copy, 4 bytes each: at most 5 bytes per byte of the copy, plus 512 KiB. Built once, the first time an encoder searches the dictionary, and shared by every encoder given it; `Dictionary::memory_usage` reports it, and `Encoder::memory_usage` does not | Cannot overflow: sized from the dictionary when built | `src/dictionary_lz77_wbtest.mbt`: "a dictionary stream's bytes do not depend on the split; encoders share one" |
| Metadata meta-blocks (`src/header.mbt`, `Decoder::metadata`) | None held: up to 16 MiB per meta-block (MSKIPLEN), skipped as the input brings them; they write no output, so the window is not grown for them | Cannot overflow: nothing is kept | `src/bounds_wbtest.mbt`: "metadata meta-blocks are skipped as they arrive, none of them held" |
| Encoded size (`compress_bound`, a whole stream) | At most `n + 5 * (n / 65,536 + 1) + 2` bytes for `n` bytes of input, what `compress_bound(n)` returns (saturating at the largest Int64 past 2^62), and 7 more for each `Flush`: a meta-block that would come out larger than its bytes is written uncompressed, 4 header bytes and 1 for the empty last meta-block an uncompressed last one needs, and the stream header | Cannot overflow: each meta-block is bounded | `src/encode_wbtest.mbt`: "incompressible input costs a few bytes per meta-block"; `src/bounds_wbtest.mbt`: "the public bounds: compress output, and flushed streams" |
| One-shot output (`decompress`, `max_output`) | `max_output` bytes when given; unlimited by default | `LimitExceeded` with resource `Output`, no `needed`, and `max_output` as `limit` | `src/decode_wbtest.mbt`: "decompress honours max_output" |
| Encoder input buffer (`src/encoder.mbt`, `data`) | The window (`(1 << window_bits) - 16` bytes, at most 16 MiB) plus `max(1 << (window_bits - 2), 64 KiB)` of slack plus one 64 KiB meta-block not encoded yet: 5.06 MiB at the default `window_bits` 22, 20.06 MiB at 24. Allocated from 1 KiB, doubling only as input arrives; once full, it slides down by at least the slack, keeping the window | Cannot overflow: a step takes no more input than fills one meta-block, and encodes it before taking more | `src/bounds_wbtest.mbt`: "the encoder's input buffer grows only with input, then slides" |
| Encoder output waiting (`src/encoder.mbt`, `writer`, a `BitPacker` of `src/internal/bits`) | One meta-block's output: at most its 64 KiB of input and 64 bytes. A compressed meta-block that grows past the size of an uncompressed one is stopped and written uncompressed | `NeedMoreOutput`; no input is taken until the caller has taken it all | `src/bounds_wbtest.mbt`: "the encoder's waiting output is at most a meta-block" |
| Decoder memory (`Decoder::memory_usage`) | The window and the prefix code tables above, which grow with the stream, and what is allocated with the decoder (below): at most `(1 << max_window_bits) + 1,343,596 + 27,793` bytes, what `decoder_memory_bound(max_window_bits~)` returns. The tables are 256 trees of each category plus the block type, block count, context map and code length codes, at 2 bytes an entry; `reset` releases the window and keeps the tables. The static dictionary is shared and an LZ77 dictionary is the caller's, so neither is counted | Cannot overflow: the window and the tables are bounded above | `src/bounds_wbtest.mbt`: "memory_usage stays within its bound after every step", "output slices, the stash and the tables stay within their bounds"; `src/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| Encoder memory (`Encoder::memory_usage`) | The input buffer and the waiting output above, which grow with the stream, and what is allocated with the encoder (below): at most `(1 << window_bits) - 16 + max(1 << (window_bits - 2), 64 KiB) + 64 KiB + 131,200` bytes (the output buffer doubles, so it holds up to twice one meta-block's output) plus `(16 << min(window_bits, 15)) + 351,628`: 6,315,516 bytes at the default `window_bits` 22, 22,044,156 at 24, what `encoder_memory_bound(window_bits~)` returns. `reset` releases the input buffer. A dictionary's index is counted by `Dictionary::memory_usage` | Cannot overflow: the input buffer and the waiting output are bounded above | `src/bounds_wbtest.mbt`: "memory_usage stays within its bound after every step", "the encoder's input buffer grows only with input, then slides", "with a dictionary, the encoder's memory stays within its bound after every step" |
| Encoder commands (`src/meta_block_writer.mbt`, `MetaBlock`) | 16,385 per meta-block: one per 4-byte match in 64 KiB, and one for the literals at the end. Five arrays of that, allocated once | Cannot overflow: matches are at least 4 bytes | `src/bounds_wbtest.mbt`: "the encoder's input buffer grows only with input, then slides", "the encoder's waiting output is at most a meta-block" |

## Encoder qualities

`quality` is clamped to 0..11. The current mappings and bounds below are
`encoder_memory_bound(quality~, window_bits=22, size_hint?)`, in bytes.
The large-hint column uses `size_hint=1048576L`; hints below 1 MiB select
the same table sizes as an omitted hint. A dictionary index is separate.

| Quality | Effective encoder | No hint / small hint | Hint at least 1 MiB | Backing test |
|---:|---|---:|---:|---|
| 0 | 4 | 6,315,516 | 6,315,516 | `src/reference_quality_wbtest.mbt`: "reference qualities: clamping and quality four ignores size hint" |
| 1 | 4 | 6,315,516 | 6,315,516 | `src/reference_quality_wbtest.mbt`: "reference qualities: clamping and quality four ignores size hint" |
| 2 | 4 | 6,315,516 | 6,315,516 | `src/reference_quality_wbtest.mbt`: "reference qualities: clamping and quality four ignores size hint" |
| 3 | 4 | 6,315,516 | 6,315,516 | `src/reference_quality_wbtest.mbt`: "reference qualities: clamping and quality four ignores size hint" |
| 4 | 4 | 6,315,516 | 6,315,516 | `src/bounds_wbtest.mbt`: "memory_usage stays within its bound after every step" |
| 5 | Reference 5 | 152,790,644 | 154,134,132 | `src/reference_quality_wbtest.mbt`: "reference qualities: random splits, flushes, dictionaries, reset and memory bounds" |
| 6 | Reference 6 | 154,101,364 | 156,755,572 | `src/reference_quality_wbtest.mbt`: "reference qualities: random splits, flushes, dictionaries, reset and memory bounds" |
| 7 | Reference 7 | 159,901,300 | 159,901,300 | `src/reference_quality_wbtest.mbt`: "reference qualities: random splits, flushes, dictionaries, reset and memory bounds" |
| 8 | Reference 8 | 168,289,908 | 168,289,908 | `src/reference_quality_wbtest.mbt`: "reference qualities: random splits, flushes, dictionaries, reset and memory bounds" |
| 9 | Reference 9 | 192,931,444 | 192,931,444 | `src/reference_quality_wbtest.mbt`: "reference qualities: random splits, flushes, dictionaries, reset and memory bounds" |
| 10 | Reference 10 | 27,197,068,000 | 27,197,068,000 | `src/reference_hq_wbtest.mbt`: "HQ streaming splits, wrong hints, flushes, dictionaries and reset stay bounded", "HQ allocation bounds use packed nodes and capacity ceilings", "HQ real parser peaks include archive growth and both cost passes", "HQ phase accounting observes splitting and clustering below the bound" |
| 11 | Reference 11 | 27,197,068,000 | 27,197,068,000 | `src/reference_hq_wbtest.mbt`: "HQ streaming splits, wrong hints, flushes, dictionaries and reset stay bounded", "HQ allocation bounds use packed nodes and capacity ceilings", "HQ real parser peaks include archive growth and both cost passes", "HQ phase accounting observes splitting and clustering below the bound" |

For qualities 5..9, let `w` be the window bits, `B` the input block size
(64 KiB, or at quality 9 `1 << min(18, w)` when `w > 16`),
`R = 2 * max(1 << w, B)`, and `M = min(R, 1 << 24)`. The bound sums:

- Input/history storage: `(1 << w) - 16 + M + 524,296` bytes, including
  padding and room for the 512 KiB read schedule. It grows with input and
  slides while retaining the window and the unfinished meta-block.
- Read staging: 524,288 bytes. The caller's split never selects parameters.
- A ring of `R` bytes, allocated when the first ring wrap needs old padding
  bytes, so reference match rejection and tail bytes agree with the CLI.
- Output capacity: `4 * (M + 512)` bytes, allowing doubling during coding.
- Commands: at most `2 * (M / 8 + B / 2 + 2)` capacity slots, charged at
  40 bytes each for fields, alignment and an array slot. The delayed-command
  threshold can be exceeded by at most one input block; doubling accounts
  for the retained capacity.
- Reference hasher buffers: `2 * (1 << bucket_bits)` bytes of counters and
  `4 * (1 << (bucket_bits + quality - 1))` bytes of positions, plus one tag
  byte per position for qualities 5 and 6. `bucket_bits` is 14 for qualities
  5 and 6 with small hints, otherwise 15; the large-hint choice requires
  `w >= 19`. Windows up to 16 use the reference's forgetful chains:
  524,290 bytes at qualities 5..8, 1,311,744 at quality 9.
  Every reference hasher also owns 98,304 bytes of static-dictionary hash
  words and lengths, initialized only for a reference-quality encoder.
- The quality-4 fixed tables below, 80 bytes for distance caches, and an
  8 MiB allowance for transient histograms, context maps, Huffman codes,
  merge candidates and coding scratch. Transient coding buffers are
  released before `step` returns; `memory_usage` reports retained buffers,
  not garbage awaiting runtime collection or runtime object headers.

The logarithm lookup is compiled as constants; it has no table allocation.
Quality 4 does not initialize the reference hash tables or context maps.
No dictionary index is charged twice. The rows for encoder input,
pending output, commands and fixed tables elsewhere in this document give
the quality-4 layout; the formula above covers qualities 5..9.

### Qualities 10 and 11

`src/reference_hq_bounds.mbt` derives these bounds from allocation sizes,
including transient coding storage. They are conservative worst-case limits,
not predictions of an application's peak. The partitioning term allows one
surviving histogram per initial block before final clustering. Upstream's
expected 16 clusters per 64-block batch is an allocation heuristic, not a
limit; assuming it would make the bound unsound on adversarial partitions.
The coding term dominates both rows, so their overall bounds coincide even
though quality 11's parser can allocate substantially more than quality 10's.
At window 24, both worst-case bounds are 54,464,238,304 bytes. The arithmetic
uses Int64 and does not allocate these amounts.

Let `W = 1 << w`, `B = ref_input_block(q, w)`,
`M = min(2 * max(W, B), 1 << 24)` and `C = M/8 + B/2 + 2`.
The retained-buffer term is:

```text
W - 16 + M + 524296 + 524288 + 2*max(W,B)
+ 4*(M+512) + 80*C + encoder_fixed_memory(w) + 80 + H(w)
H(w) = 8*W + 4*131072 + 4*384
     + 2*32768 + 4*(31705+88+8+38)
```

`H` counts H10's UInt32 buckets and children, candidate pairs, static-word
lookup tables, suffix groups and per-length candidates. It is exactly
34,273,148 bytes at window 22 and 134,936,444 at window 24; the forest alone
is respectively 32 MiB and 128 MiB. A true one-shot input may allocate two
children per input byte instead of per window byte. A size hint cannot
enable that optimization. Preparation clears buckets while retaining the
forest, including across position wraps. The test
`src/reference_hq_wbtest.mbt`: "H10 tree allocation, preparation and position wrap retain their layout"
checks the exact byte count, shortened forest and reset lifecycle.
The full window-24 forest and streaming growth checks are in
`src/reference_hq_wbtest.mbt`: "H10 full window-24 forests retain their layout and grow within the bound"
on native; smaller layouts, a short window-24 forest and position wraps run
on every target, avoiding repeated 128 MiB allocations on the other backends.

The bound adds the larger of parsing and coding scratch, which have separate
lifetimes. Parsing uses four 32-bit node arrays of `B+1` entries, `B+2`
Float32 literal prefix sums, 704 command costs, 64 distance costs, a
768-entry literal histogram, 56 queue entries and four initial distances.
Quality 10 also needs three literal-window counters. Quality 11 adds `B`
match counts, a doubled-capacity archive of at most `512*B` UInt32 entries
(including raw-dictionary candidates), and 1,280 entries for its second cost
model. At `B=262144`, these bounds are 5,249,300 and 543,173,896 bytes.
`src/reference_hq_wbtest.mbt`: "HQ real parser peaks include archive growth and both cost passes"
measures the live scratch during actual parses, including archive capacity
changes, the literal estimator and the second cost model. Its two-symbol
262,144-byte q11 input grows the archive and reaches 23,080,200 bytes of
parser scratch. Replacing either quality's parser bound by DP storage alone
fails this test; a larger coding bound cannot conceal missing parser storage.

Coding is bounded by the larger of block partitioning, context clustering
and Huffman construction, plus completed splits and symbol vectors. The
source formulas enumerate the symbol/ID arrays, switch bitmaps, Double path
costs, histogram storage, doubled capacities, cluster sizes, maps and
remapping, and the pair queues capped at 64 pairs per surviving histogram.
Context clustering has at most 16,384 literal input histograms, 1,024
distance input histograms and 256 final histograms per category. This
derivation uses the port's Int32 symbol vectors and its actual histogram
and pair layout, rather than copying C allocation sizes or adding an
unexplained scratch allowance. As elsewhere, runtime object headers and
garbage awaiting collection are outside the accounting model.

### Measured HQ peaks

Measured on 2026-11-18, native MoonBit 0.10.20+65efd5b93 on Linux x86_64
(Intel Core i5-10400F), with `scripts/measure_memory.mbtx` under the shared
gate lock. These are peaks of accounted allocations on the named inputs,
not RSS or guaranteed limits. All table values are bytes.

| Quality | Window | `bench_text` | `bench_binary` | `alternating512` | Worst-case bound |
|---:|---:|---:|---:|---:|---:|
| 10 | 22 | 44,592,696 | 6,385,248 | 60,030,477 | 27,197,068,000 |
| 11 | 22 | 54,034,928 | 11,436,640 | 60,295,682 | 27,197,068,000 |
| 10 | 24 | 145,255,992 | 6,385,248 | 160,693,773 | 54,464,238,304 |
| 11 | 24 | 154,698,224 | 11,436,640 | 160,958,978 | 54,464,238,304 |

`bench_text` (524,288 bytes) and `bench_binary` (131,072 bytes) are the
existing benchmark corpus files, written under `_build/compare/ratio/` by
`scripts/compare_codecs.mbtx`. Their contents come from
`bench/src/data_test.mbt`; the measurement script prints their SHA-256 hashes.
`alternating512` is 1,048,576 seeded random bytes: every 512 bytes selects
the next of eight disjoint 32-byte alphabets. The script constructs it from
LCG seed 1951. It produces 2,048 initial literal blocks and 256 surviving
histograms before final clustering at both qualities and windows.

Encodes use a correct size hint, whole-input `Finish`, and 4 KiB output
buffers. The observer sums the encoder's actual retained backing storage
with actual lengths/capacities of live phase scratch. It releases refinement
storage before clustering and parser storage before coding; aliases are not
charged as new histogram data. Consumed symbol arrays include their copy
overlap, or transfer their full backing buffer on native/linear Wasm when
exclusively owned. A histogram has 24 bytes of fields/alignment
and an 8-byte array slot, matching the bound's 32-byte charge; merge-queue
entries also use its 32-byte charge. Runtime headers, observer state,
caller-owned input/output and garbage awaiting collection are excluded.
Container growth charges the resulting capacity, as `memory_usage` does;
allocator-internal copies during growth are outside this capacity model.
The small Huffman/map helpers have a separate envelope based on actual tree
and map counts; the script asserts that the entire envelope is below an
observed peak before reporting that peak. It never substitutes this envelope
for a measured value.

The binary corpus fits a final first input block, so its forest is sized to
the input and its measured peak is the same at both windows. The other two
inputs allocate the full 32 MiB or 128 MiB forest. To approach the worst-case
bound, the partitioning/clustering term would have to grow: many more short
blocks in an 8 MiB or 16 MiB meta-block would have to retain distinct
histograms through batch merging. That increases histogram storage and the
queue of up to 64 merge pairs per surviving histogram. The final 256-tree
limit does not cap these intermediate allocations.

Reproduce from the repository root, with `GATES_LOCK` set to the shared lock:

```sh
flock "$GATES_LOCK" moon run brotli/scripts/measure_memory.mbtx
```

Two optional arguments select different text and binary corpus files.

## Fixed per decoder

Allocated when the decoder is made and counted by `Decoder::memory_usage`,
27,793 bytes in all (`src/bounds_wbtest.mbt`: "a new decoder holds exactly
its fixed memory"), apart from the static dictionary, which is shared:

| Structure | Size |
|---|---|
| Context maps | 16 KiB (literals) + 1 KiB (distances) |
| Code length scratch, table builder scratch, trees' offsets, block type state | About 10 KiB |
| Transformed dictionary word | 37 bytes |
| The static dictionary and transform tables | 122,784 + about 1 KiB, shared by all decoders and not counted |

## Fixed per encoder

Allocated when the encoder is made and counted by `Encoder::memory_usage`
(`src/bounds_wbtest.mbt`: "a new encoder holds exactly its fixed memory"):

| Structure | Size |
|---|---|
| LZ77 hash table (`src/internal/lz77`) | `4 << min(window_bits, 15)` positions, 4 bytes each: `16 << min(window_bits, 15)` bytes, 512 KiB from `window_bits` 15 up |
| Meta-block commands, their histograms, codes and the code writer's scratch, and the distance ring | 351,628 bytes: five arrays of 16,385 (320 KiB), the histograms, lengths and codes of the 256-, 704- and 64-symbol alphabets, `CodeMaker`'s 5,760 bytes and the run-length coded lengths |

## Left to the caller

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| Total output of a stream | The stream | `step` hands it out in slices; the caller decides what to keep |
| Input chunks | What the caller passes | `step` keeps no reference to them after it returns; the encoder copies what it takes |
| `compress` output | The input | It returns the whole stream; use `Encoder` to stream |
| `decompress` output | The stream | It returns the whole output; pass `max_output`, or use `Decoder` |
| A dictionary's content | The caller's dictionary | `Dictionary` holds a view of the caller's bytes, which stay alive as long as it does; decoders and encoders keep the `Dictionary`, not a copy. Its index, built the first time an encoder searches it, is in the table above |
