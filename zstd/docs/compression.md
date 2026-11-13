# Compression levels and strategies

This is the implementation and measurement record for fast and double-fast, measured on
2026-11-13 with MoonBit 0.10.20, Zstandard CLI 1.5.7 and Node 26.13.1.
The greedy, lazy and tree strategies are not implemented yet.

`internal/seqenc` owns `Distance`, `OffsetValue`, `Repeats`, `Block` and
`Writer`. Raw distances are converted only by `Repeats::encode`, through
the resolver also used by the decoder. The resolver owns the zero-literal
shift and repeat-3-minus-1. A block's repeats and tables are speculative
until the compressed block is selected; raw, RLE and zero-sequence blocks
leave the committed sequence state alone. Reset drops all frame history.
Length baselines, extra-bit widths and predefined distributions are shared
with the decoder through `seqenc/tables.mbt`.

Each LL/OF/ML stream chooses its own mode. A single symbol uses RLE, or
Repeat when the previous table is that same RLE table; it never builds an
FSE_Compressed single-symbol table. Otherwise the candidates are
Predefined, a valid previous table, and a newly normalized table with
accuracy log at most 9 (LL/ML) or 8 (OF). The cost estimate is the sum of
symbol counts times approximate `log2(table_size / probability)`, plus
description bytes and the initial state. Log probabilities interpolate
linearly in eighth bits between powers of two; each symbol's total rounds
up to a whole bit. Zero probabilities make a candidate ineligible. The
new description's byte count is measured exactly; ties favour an existing
table. This deliberately simple model avoids a full trial bitstream for
each candidate. Actual block bytes, including padding, decide compressed
versus raw, so an optimistic estimate cannot grow the frame unboundedly.

The sequence stream writes transitions and extras in the reverse of the
decoder's read order. Offset values and extras use UInt32, avoiding a
signed `1 << 31`. Each offset extra write is at most 31 bits; BitPacker's
JS implementation splits a write that would overflow its accumulator.
Every partial-byte alignment is tested through a backward reader. Actual
encoder windows need at most 21 offset extra bits, so external window
fixtures exercise window minus one, while width 31 is a packing test.

`internal/match/Fast` follows
[Zstandard 1.5.7's no-dictionary fast loop](https://github.com/facebook/zstd/blob/v1.5.7/lib/compress/zstd_fast.c#L192).
It uses one hash table and a sliding byte buffer of at most window + one
block. Hash positions rebase after each block, avoiding counter overflow
on long frames. The finder sees only complete cutter blocks, never step
boundaries, and retains history for raw and RLE blocks too. Hash widths
and constants follow `ZSTD_hash{4,5,6,7}`; four-byte matches remain eligible
regardless of hash width. The scalar, checked implementation preserves the
reference pipeline's lookup and insertion order. It searches adjacent
pairs, starting with a gap of `max(targetLength, 1) + 1`, increasing it by
one per 128 searched bytes. Repeat one at the next pair receives priority
and catches back at most one byte. Hash matches catch back through pending
literals. After a match, insertion uses the original search position + 2
and match end - 2, then immediate repeat two runs before search restarts.
Only the two reference search offsets participate; encoded repeat history
still comes from the committed sequence writer.

Levels 1..4 select their finder from the size-class row's strategy, rather
than the level number. Level two at more than 128 KiB and at most 256 KiB
therefore uses double-fast; its smaller and larger rows use fast. A row
whose strategy is greedy, lazy, lazy2, btlazy2 or btopt temporarily uses
level four's row if it is double-fast, otherwise level three's row, in the
same size class. This applies to levels 5..12 and to level four's greedy
rows at at most 16 KiB and at more than 128 KiB through 256 KiB. All
parameters, including window and both hashes, come from that fallback row.
The later hash-chain implementation will replace this temporary mapping.

Literals choose raw, RLE, a new Huffman tree, or a valid previous tree
(Treeless). A new tree replaces the previous one only when written into
an accepted block. Raw/RLE blocks preserve it; reset invalidates it.
Four Huffman streams now compute their jump-table sizes first and write
directly to the block output, removing the private stream buffer and copy.
Only the small Huffman weight scratch remains. The total conservative
encoder bound, including match and sequence storage, is 6,582,176 bytes;
the accounting and limit tests are in RESOURCE_BOUNDS.md.

## Double-fast matching

`internal/match/Dfast` follows the no-dictionary loop of
[Zstandard 1.5.7's double-fast encoder](https://github.com/facebook/zstd/blob/v1.5.7/lib/compress/zstd_double_fast.c).
Its long table has `2^hashLog` positions hashed over eight bytes; the
short table has `2^chainLog` positions hashed over `minMatch` bytes.
It checks repeat one at the current position plus one first, then the
long table, then the short table. A short match competes with the long
candidate at the next search position. Hash matches extend backward
through pending literals; repeat matches keep their literal prefix.
After each match it inserts the complementary positions and checks
immediate repeat two. The step starts at one after each match and grows
by one for every 256 bytes searched without a match. The next long
candidate is loaded before the current insertion, preserving the
reference's behavior when hashes collide. Prefetching and unsafe dummy
loads are replaced with scalar, checked candidate eligibility.

Both finders use the cutter's complete blocks, retain history even for
raw/RLE blocks, reject positions before the frame or beyond the window,
and rebase both tables when discarding old bytes. Double-fast completes
cross-boundary hashes only once the next block
provides their lookahead; fast keeps the reference's sparse insertions.
An exact window-distance candidate is allowed; libzstd's stricter block
prefix threshold and its start sentinel need not give identical matches.
Sequence coding remains responsible for the actual repeat transitions.
The finder keeps its two search offsets as the reference loop does;
the block's encoded repeat history is committed only if selected.

The memory limit is derived from the selected parameters: window plus
one block, `4 * (2^hashLog + 2^chainLog)` bytes of positions for double-fast
(fast has only its hash and 12 repeat bytes), and the other bounded
encoder structures in RESOURCE_BOUNDS.md. The maximum is the large-input
level-four row (windowLog 21, hashLog 18, chainLog 18); later strategies
temporarily use no larger row. Sequence scratch still has the shared
BitPacker's doubling allowance. Exact reservation could reduce that
allowance, but would require changing the shared packer or writer; it is
left for a separate change to the already completed entropy layer.

## Compression sizes

The 23 corpus files were checked against every size and SHA-256 in
`bench/compare/corpora.tsv`. Both encoders include checksums and known
content size. The gaato rows use `compress`; reference rows use a named
file with `zstd -N --check -c -q` for N=1..4, allowing the reference to choose its
size class. All 100 gaato outputs (four levels, 23 corpus files plus two
bench inputs) decode back with gaato and `zstd -d`. Timing was disabled.

Reproduce from the repository root (substitute the corpus directories):

```sh
moon run scripts/compare_codecs.mbtx -- ratio --format zstd --time 0 --corpus /home/gaato/works/deflate-research/corpus/silesia --corpus /home/gaato/works/deflate-research/corpus/canterbury
```

Delta is `(gaato_bytes / reference_bytes - 1) * 100`; negative is smaller.
The table below includes both parameter adjustment and the corrected fast
search schedule. The two supplementary bench inputs are excluded from
corpus totals.

| Corpus / file | gaato 1 | zstd -1 | delta | gaato 2 | zstd -2 | delta | gaato 3 | zstd -3 | delta | gaato 4 | zstd -4 | delta |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| _build/compare/ratio/bench_text | 158919 | 158899 | +0.01% | 157064 | 157042 | +0.01% | 148599 | 148537 | +0.04% | 148279 | 148212 | +0.05% |
| _build/compare/ratio/bench_binary | 118323 | 118359 | -0.03% | 108289 | 108864 | -0.53% | 98818 | 100216 | -1.39% | 93672 | 96133 | -2.56% |
| silesia/mr | 3821885 | 3817777 | +0.11% | 3597571 | 3596433 | +0.03% | 3548083 | 3548071 | +0.00% | 3487316 | 3489400 | -0.06% |
| silesia/nci | 2833518 | 2853982 | -0.72% | 2875575 | 2890691 | -0.52% | 2822975 | 2835400 | -0.44% | 2823574 | 2836688 | -0.46% |
| silesia/sao | 6251270 | 6249095 | +0.03% | 5806197 | 5804517 | +0.03% | 5550898 | 5531939 | +0.34% | 5423232 | 5401813 | +0.40% |
| silesia/xml | 695210 | 694925 | +0.04% | 679411 | 677523 | +0.28% | 636752 | 636016 | +0.12% | 635514 | 634478 | +0.16% |
| silesia/osdb | 3726324 | 3728615 | -0.06% | 3488798 | 3491504 | -0.08% | 3498425 | 3501634 | -0.09% | 3472969 | 3477593 | -0.13% |
| silesia/samba | 5491070 | 5500201 | -0.17% | 5204281 | 5228477 | -0.46% | 4950010 | 4957768 | -0.16% | 4907735 | 4919655 | -0.24% |
| silesia/x-ray | 6771540 | 6772240 | -0.01% | 6677186 | 6680315 | -0.05% | 6084823 | 6086002 | -0.02% | 5710203 | 5712031 | -0.03% |
| silesia/dickens | 4261938 | 4262734 | -0.02% | 3865228 | 3867462 | -0.06% | 3662262 | 3664984 | -0.07% | 3580094 | 3588622 | -0.24% |
| silesia/mozilla | 20088042 | 19983517 | +0.52% | 19031102 | 18951213 | +0.42% | 18453645 | 18281292 | +0.94% | 18246076 | 18103876 | +0.79% |
| silesia/ooffice | 3604413 | 3593264 | +0.31% | 3319245 | 3311698 | +0.23% | 3141137 | 3128288 | +0.41% | 3066258 | 3053902 | +0.40% |
| silesia/reymont | 2146843 | 2150826 | -0.19% | 2064616 | 2068474 | -0.19% | 1935883 | 1937977 | -0.11% | 1913933 | 1917276 | -0.17% |
| silesia/webster | 13658277 | 13669761 | -0.08% | 12800667 | 12824630 | -0.19% | 12085709 | 12107198 | -0.18% | 11892552 | 11925012 | -0.27% |
| canterbury/sum | 13616 | 13624 | -0.06% | 13471 | 13473 | -0.01% | 13368 | 13379 | -0.08% | 13064 | 13070 | -0.05% |
| canterbury/ptt5 | 51641 | 51670 | -0.06% | 52727 | 52759 | -0.06% | 54297 | 54424 | -0.23% | 54482 | 54596 | -0.21% |
| canterbury/cp.html | 8823 | 8824 | -0.01% | 8631 | 8633 | -0.02% | 8464 | 8468 | -0.05% | 8434 | 8438 | -0.05% |
| canterbury/xargs.1 | 1868 | 1864 | +0.21% | 1852 | 1851 | +0.05% | 1800 | 1803 | -0.17% | 1800 | 1767 | +1.87% |
| canterbury/fields.c | 3558 | 3560 | -0.06% | 3589 | 3593 | -0.11% | 3370 | 3384 | -0.41% | 3370 | 3212 | +4.92% |
| canterbury/lcet10.txt | 158451 | 158524 | -0.05% | 148574 | 148564 | +0.01% | 141027 | 141028 | -0.00% | 140526 | 140402 | +0.09% |
| canterbury/alice29.txt | 59650 | 59661 | -0.02% | 57363 | 57352 | +0.02% | 56984 | 56974 | +0.02% | 56984 | 54286 | +4.97% |
| canterbury/grammar.lsp | 1344 | 1341 | +0.22% | 1334 | 1333 | +0.08% | 1303 | 1295 | +0.62% | 1303 | 1258 | +3.58% |
| canterbury/kennedy.xls | 115586 | 115395 | +0.17% | 111373 | 112242 | -0.77% | 112060 | 111831 | +0.20% | 111064 | 110925 | +0.13% |
| canterbury/asyoulik.txt | 54524 | 54516 | +0.01% | 51866 | 51858 | +0.02% | 50336 | 50328 | +0.02% | 51156 | 51146 | +0.02% |
| canterbury/plrabn12.txt | 217869 | 217845 | +0.01% | 198499 | 198467 | +0.02% | 191716 | 191688 | +0.01% | 189649 | 189624 | +0.01% |
| **silesia total** | 73350330 | 73276937 | +0.10% | 69409877 | 69392937 | +0.02% | 66370602 | 66216569 | +0.23% | 65159456 | 65060346 | +0.15% |
| **canterbury total** | 686930 | 686824 | +0.02% | 649279 | 650125 | -0.13% | 634725 | 634602 | +0.02% | 631832 | 628724 | +0.49% |

### Remaining outliers

No Silesia or Canterbury file exceeds +3% at levels one through three.
At level four, `fields.c` (+4.92%), `grammar.lsp` (+3.58%) and
`alice29.txt` (+4.97%) use the temporary level-three double-fast row
because the requested row is greedy. This remains a limitation until the
later strategies land. Forcing only `--zstd=strat=2` on the reference's
level-four row gives 3,377 / 1,295 / 55,794 bytes respectively, versus its
normal greedy 3,212 / 1,258 / 54,286. The remaining difference on alice
also reflects the fallback hash parameters (the level-three reference is
56,974 versus our 56,984). No corpus-specific adjustment was made.

## Known-size parameter adjustment

`params_for` applies the no-dictionary part of
[ZSTD_adjustCParams_internal, v1.5.7](https://github.com/facebook/zstd/blob/v1.5.7/lib/compress/zstd_compress.c#L1473)
after selecting a size-class row, before choosing a temporary strategy
fallback. For sizes at most 2^30, shrink windowLog to the rounded-up
source log, with a minimum source log of 6. For every known size, cap
hashLog at that windowLog + 1, and reduce chainLog by
`max(cycleLog - windowLog, 0)`, where cycleLog is chainLog minus one for
btlazy2/btopt and chainLog otherwise. Only then restore windowLog to the
frame minimum of 10. An unknown size keeps its large-input row unchanged;
a known zero means an empty source, not the legacy public C API's
zero-as-unknown alias.

Dictionary-mode and tagged-dictionary adjustments do not apply. The
row-finder hash cap cannot affect levels 1..12: their hashLog is at most
23, below its smallest cap of 28. Reference compile-time strategy
exclusions are not used; our explicit fallback chooses and adjusts its
own row. No searchLog, minMatch or targetLength adjustment applies here.
Tests pin window/chain/hash rows for ten sizes at every level, including
tiny sources and tree strategies, plus the size-class and 2^30 boundaries.
For example, level three at 1,000 bytes now uses 10/10/11 instead of
10/14/15. Table allocations only shrink, so the 6,582,176-byte maximum
encoder bound is unchanged.

## Closed investigation: level-two kennedy.xls

The earlier +11.16% gap was a divergence from the reference fast
algorithm, not a retained compression tradeoff. The old loop searched
single positions with `max(targetLength, 1) + ((p-anchor) >> 8)`, tried
all three recent distances, extended repeat matches arbitrarily backward,
inserted from the caught-back match start, and completed cross-block
hashes. The reference searches pairs, grows the gap every 128 bytes,
preserves pipelined hash lookups and conditional next-position insertions,
uses only repeat one ahead and immediate repeat two, catches repeats back
at most one byte, and inserts original-search-position + 2. These
simplifications have all been removed. Safe candidate checks replace
unsafe dummy loads and prefetches without changing the search order.

Instrumentation of `ZSTD_compressBlock_fast_noDict_generic` in the
v1.5.7 source, run with `-2 --check -c -q kennedy.xls`, recorded each
match's absolute start, LL, ML and raw distance. The old finder agreed on
only 25,066 (start, ML, distance) tuples; 23,281 reference match starts
were absent (covering 201,555 reference match bytes, not an independent
sum of lost compression). Its first match was at 44, LL=44, ML=4,
distance=8; reference starts at 66, LL=66, ML=6, distance=8. The corrected
finder agrees on **all 99,302 tuples, in order, across all eight blocks**.
A deterministic synthetic collision/repetition fixture pins a fingerprint
of every (LL, ML, distance) against instrumented reference output for
hash widths 4..7 and targetLength 0/8, preventing the scheduling regression
without depending on the external corpus in unit tests.

| Measurement | Before | Corrected | zstd -2 |
|---|---:|---:|---:|
| Frame bytes | 124,773 | 111,373 | 112,242 |
| Delta | +11.16% | -0.77% | — |
| Sequences | 98,842 | 99,302 | 99,302 |
| Literals | 95,208 | 85,788 | 85,788 |
| Literal-section bytes | 74,723 | 64,884 | 64,677 |
| Sequence-section bytes | 50,013 | 46,452 | 47,528 |
| Frame/block/checksum overhead | 37 | 37 | 37 |

The correction saves 13,400 bytes: 9,839 in literal sections and 3,561
in sequence sections. The remaining -869 bytes versus reference consist
of +207 literal bytes and -1,076 sequence bytes, with identical matches
and framing. They belong to entropy/table and offset-code selection:
`seqenc` may use any legal repeat code, including the initial third
repeat where reference fast explicitly stores a new offset. For example,
the first match's distance 8 is Offset_Value 3 here versus 11 there;
both establish [8, 1, 4]. Bit-identical entropy coding is not a goal.
No fast-search contribution remains unexplained on this file.

Candidate eligibility still deliberately permits the exact window
distance relative to the current position, unlike libzstd's stricter
block-prefix threshold. The retained bytes and explicit distance check
make this safe; existing exact-window tests pin it. It does not affect
kennedy.xls (1,029,744 bytes fits inside level two's 1 MiB window), as
the complete match comparison confirms.

The supplementary `bench_binary` level-one loss also closes: 123,123
becomes 118,323 bytes versus reference 118,359 (-0.03%). At levels three
and four, kennedy's earlier small entropy differences remain: 112,060
versus 111,831 and 111,064 versus 110,925 bytes. Those double-fast paths
were not changed by the fast-search correction.
