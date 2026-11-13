# Compression levels and strategies

This is the implementation and measurement record for fast, double-fast,
greedy, lazy and lazy2, measured on
2026-11-13 with MoonBit 0.10.20, Zstandard CLI 1.5.7 and Node 26.13.1.
Binary-tree and optimal strategies are not implemented.

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
regardless of hash width. The target-specific implementations preserve the
reference pipeline's lookup and insertion order. It searches adjacent
pairs, starting with a gap of `max(targetLength, 1) + 1`, increasing it by
one per 128 searched bytes. Repeat one at the next pair receives priority
and catches back at most one byte. Hash matches catch back through pending
literals. After a match, insertion uses the original search position + 2
and match end - 2, then immediate repeat two runs before search restarts.
Only the two reference search offsets participate; encoded repeat history
still comes from the committed sequence writer.

Levels 1..12 select their finder from the size-class row's strategy, rather
than the level number. Level two at more than 128 KiB and at most 256 KiB
therefore uses double-fast; its smaller and larger rows use fast. A row
whose strategy is greedy, lazy or lazy2 uses that strategy with its own
adjusted numbers, including level four's greedy rows. Btlazy2 and Btopt
rows use lazy2 with **all six adjusted numeric parameters unchanged**.
Adjustment happens before mapping, retaining the tree cycle bit when
shrinking chainLog. The affected rows are levels 9..12 at at most 16 KiB,
and levels 11..12 above 16 KiB through 256 KiB. These approximations
avoid introducing binary trees or optimal parsing into a hash-chain
encoder; they need not match those strategies' compression.

Literals choose raw, RLE, a new Huffman tree, or a valid previous tree
(Treeless). A new tree replaces the previous one only when written into
an accepted block. Raw/RLE blocks preserve it; reset invalidates it.
Four Huffman streams now compute their jump-table sizes first and write
directly to the block output, removing the private stream buffer and copy.
Only the small Huffman weight scratch remains. The total conservative
encoder bound, including match and sequence storage, is 56,913,824 bytes;
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
candidate is loaded after the current insertion (the current candidate
was loaded before insertion), preserving the
reference's behavior when hashes collide. Prefetching and unsafe dummy
loads are replaced with explicit candidate eligibility checks.

All finders use the cutter's complete blocks, retain history even for
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
encoder structures in RESOURCE_BOUNDS.md. The double-fast maximum is the
large-input level-four row (windowLog 21, hashLog 18, chainLog 18). The
overall maximum now comes from level twelve, derived below.
Sequence scratch still has the shared
BitPacker's doubling allowance. Exact reservation could reduce that
allowance, but would require changing the shared packer or writer; it is
left for a separate change to the entropy writer.

## Hash chains and delayed matches

`internal/match/Lazy` transcribes the no-dictionary
[ZSTD_compressBlock_lazy_generic](https://github.com/facebook/zstd/blob/v1.5.7/lib/compress/zstd_lazy.c)
with depth 0 (greedy), 1 (lazy) or 2 (lazy2), and `ZSTD_HcFindBestMatch`.
Every search catches up hash heads and circular chain links to just before
the searched position. It examines at most `2^searchLog` candidates,
stops before following an overwritten ring link, and stops on a match
reaching the block end. minMatch selects a hash width clamped to 4..6,
exactly as the reference HC parser does; eligible matches remain at least
four bytes, including mapped minMatch=3 tree rows. The reference HC search
does **not** use targetLength as an early-exit threshold; that parameter
is retained in the selected row but does not bound this algorithm.

Repeat one at position + 1 is considered first, and greedy takes it
immediately. Otherwise a strictly longer chain match can replace it.
Lazy's next-position repeat gain is `3*ML`, compared with
`3*oldML - highbit(oldOffBase) + 1`; new offsets use
`4*ML - highbit(offBase)` versus `4*oldML - highbit(oldOffBase) + 4`.
Lazy2 additionally searches two bytes ahead, using repeat multiplier 4
and new-offset penalty 7. A winning new offset restarts the lookahead
loop. Here offBase is one for repeat one (highbit zero) and distance + 3
for a new offset, matching the reference's gain arithmetic. The code uses
a zero-distance sentinel for repeat one and omits rechecking that same
repeat once selected: its length at the same position is unchanged, and
at a later position it ends at the same mismatch, so its gain cannot win.
New offsets catch back
through literals; repeats preserve their literal prefix. Immediate repeat
two swaps the two search offsets. Encoded repeat transitions still belong
to the committed sequence writer, including when a legal repeat code can
represent a new-offset search decision.

After 2 KiB without a match, the reference's skip step exceeds eight:
only the previous searched position is inserted rather than every skipped
position. Finding a match disables that mode. Subsequent searches insert
the skipped match bytes as the reference does. Cross-block tail hashes are
completed only when the next complete block supplies enough bytes.

The bounded byte prefix and both position tables rebase after a block.
Subtracting the discarded byte count invalidates expired links/heads;
a ring bias preserves each surviving chain slot under this subtraction.
Search explicitly rejects a distance beyond the window and positions
before retained frame history. Like fast/dfast, the exact window distance
is eligible. This boundary policy can differ from libzstd's stricter
prefix threshold, especially once a frame slides its window.

### Reference finder selection

In v1.5.7 `ZSTD_resolveRowMatchFinderMode` enables rows automatically for
greedy through lazy2 **when adjusted windowLog > 14**; this decision does
not depend on SIMD availability or CPU architecture. Thus on the default
x86-64 CLI build, greedy/lazy/lazy2 rows at at most 16 KiB use HC, and
larger inputs use rows at levels 5..10. Levels 9..10 use binary trees at at most 16 KiB;
levels 11..12 use rows above 256 KiB and binary trees/optimal parsing
below that boundary. At levels 6..8 the at-most-16-KiB rows are lazy2,
still HC. Level five's smallest row is lazy. Unknown sizes keep the
large-input rows and use rows at every level 5..12.

This implementation chooses HC, a complete reference algorithm with a
scalar implementation and explicit chain bounds. The CLI exposes
`--no-row-match-finder`; primary algorithm comparisons use named files
with `zstd -N --no-row-match-finder --check -c -q FILE`. The ordinary
`zstd -N --check -c -q FILE` is measured separately below, so row-finder
effects remain visible. Disabling rows does not turn tree rows into HC;
their documented lazy2 mapping is a separate approximation.

Large-input levels 5..12 keep the reference's full logs: window 21..22,
chain 18..22 and hash 19..23. At level twelve the tables alone occupy
`4*(2^22 + 2^23) = 50,331,648` bytes (48 MiB). Adding the 4 MiB window
and one 128 KiB block gives matcher capacity 54,657,024 bytes; the full
encoder bound is **56,913,824 bytes (about 54.28 MiB)**. No parameter was
capped below the selected reference row. RESOURCE_BOUNDS.md derives the
remaining 2,256,800 bytes and names tests reaching the matcher maximum.

## Compression sizes

The 23 corpus files were verified against every byte count and SHA-256
in `bench/compare/corpora.tsv`. Both encoders include checksums and known
content size. gaato uses `compress`; HC uses named files with
`zstd -N --no-row-match-finder --check -c -q FILE`; default uses
`zstd -N --check -c -q FILE`, N=1..12. All **300 gaato frames** (12 levels,
23 corpus files and two supplementary bench inputs) decode back with
gaato and `zstd -d`. Timing was disabled. The supplementary inputs are
excluded from corpus totals.

Reproduce from the repository root (substitute the corpus directories):

```sh
moon run scripts/compare_codecs.mbtx -- ratio --format zstd --only gaato/zstd --time 0 --corpus /home/gaato/works/deflate-research/corpus/silesia --corpus /home/gaato/works/deflate-research/corpus/canterbury
```

The driver prints both reference configurations. Δ is
`(gaato_bytes / reference_bytes - 1) * 100`; negative means smaller.
Sizes below are bytes, with each delta compared to its named finder.
### Levels 1–4

| Corpus / file | gaato 1 | HC 1 | default 1 | Δ HC | Δ default | gaato 2 | HC 2 | default 2 | Δ HC | Δ default | gaato 3 | HC 3 | default 3 | Δ HC | Δ default | gaato 4 | HC 4 | default 4 | Δ HC | Δ default |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| silesia/mr | 3821885 | 3817777 | 3817777 | +0.11% | +0.11% | 3597571 | 3596433 | 3596433 | +0.03% | +0.03% | 3548083 | 3548071 | 3548071 | +0.00% | +0.00% | 3487316 | 3489400 | 3489400 | -0.06% | -0.06% |
| silesia/nci | 2833518 | 2853982 | 2853982 | -0.72% | -0.72% | 2875575 | 2890691 | 2890691 | -0.52% | -0.52% | 2822975 | 2835400 | 2835400 | -0.44% | -0.44% | 2823574 | 2836688 | 2836688 | -0.46% | -0.46% |
| silesia/sao | 6251270 | 6249095 | 6249095 | +0.03% | +0.03% | 5806197 | 5804517 | 5804517 | +0.03% | +0.03% | 5550898 | 5531939 | 5531939 | +0.34% | +0.34% | 5423232 | 5401813 | 5401813 | +0.40% | +0.40% |
| silesia/xml | 695210 | 694925 | 694925 | +0.04% | +0.04% | 679411 | 677523 | 677523 | +0.28% | +0.28% | 636752 | 636016 | 636016 | +0.12% | +0.12% | 635514 | 634478 | 634478 | +0.16% | +0.16% |
| silesia/osdb | 3726324 | 3728615 | 3728615 | -0.06% | -0.06% | 3488798 | 3491504 | 3491504 | -0.08% | -0.08% | 3498425 | 3501634 | 3501634 | -0.09% | -0.09% | 3472969 | 3477593 | 3477593 | -0.13% | -0.13% |
| silesia/samba | 5491070 | 5500201 | 5500201 | -0.17% | -0.17% | 5204281 | 5228477 | 5228477 | -0.46% | -0.46% | 4950010 | 4957768 | 4957768 | -0.16% | -0.16% | 4907735 | 4919655 | 4919655 | -0.24% | -0.24% |
| silesia/x-ray | 6771540 | 6772240 | 6772240 | -0.01% | -0.01% | 6677186 | 6680315 | 6680315 | -0.05% | -0.05% | 6084823 | 6086002 | 6086002 | -0.02% | -0.02% | 5710203 | 5712031 | 5712031 | -0.03% | -0.03% |
| silesia/dickens | 4261938 | 4262734 | 4262734 | -0.02% | -0.02% | 3865228 | 3867462 | 3867462 | -0.06% | -0.06% | 3662262 | 3664984 | 3664984 | -0.07% | -0.07% | 3580094 | 3588622 | 3588622 | -0.24% | -0.24% |
| silesia/mozilla | 20088042 | 19983517 | 19983517 | +0.52% | +0.52% | 19031102 | 18951213 | 18951213 | +0.42% | +0.42% | 18453645 | 18281292 | 18281292 | +0.94% | +0.94% | 18246076 | 18103876 | 18103876 | +0.79% | +0.79% |
| silesia/ooffice | 3604413 | 3593264 | 3593264 | +0.31% | +0.31% | 3319245 | 3311698 | 3311698 | +0.23% | +0.23% | 3141137 | 3128288 | 3128288 | +0.41% | +0.41% | 3066258 | 3053902 | 3053902 | +0.40% | +0.40% |
| silesia/reymont | 2146843 | 2150826 | 2150826 | -0.19% | -0.19% | 2064616 | 2068474 | 2068474 | -0.19% | -0.19% | 1935883 | 1937977 | 1937977 | -0.11% | -0.11% | 1913933 | 1917276 | 1917276 | -0.17% | -0.17% |
| silesia/webster | 13658277 | 13669761 | 13669761 | -0.08% | -0.08% | 12800667 | 12824630 | 12824630 | -0.19% | -0.19% | 12085709 | 12107198 | 12107198 | -0.18% | -0.18% | 11892552 | 11925012 | 11925012 | -0.27% | -0.27% |
| canterbury/sum | 13616 | 13624 | 13624 | -0.06% | -0.06% | 13471 | 13473 | 13473 | -0.01% | -0.01% | 13368 | 13379 | 13379 | -0.08% | -0.08% | 13064 | 13070 | 13070 | -0.05% | -0.05% |
| canterbury/ptt5 | 51641 | 51670 | 51670 | -0.06% | -0.06% | 52727 | 52759 | 52759 | -0.06% | -0.06% | 54297 | 54424 | 54424 | -0.23% | -0.23% | 54482 | 54596 | 54596 | -0.21% | -0.21% |
| canterbury/cp.html | 8823 | 8824 | 8824 | -0.01% | -0.01% | 8631 | 8633 | 8633 | -0.02% | -0.02% | 8464 | 8468 | 8468 | -0.05% | -0.05% | 8434 | 8438 | 8438 | -0.05% | -0.05% |
| canterbury/xargs.1 | 1868 | 1864 | 1864 | +0.21% | +0.21% | 1852 | 1851 | 1851 | +0.05% | +0.05% | 1800 | 1803 | 1803 | -0.17% | -0.17% | 1768 | 1767 | 1767 | +0.06% | +0.06% |
| canterbury/fields.c | 3558 | 3560 | 3560 | -0.06% | -0.06% | 3589 | 3593 | 3593 | -0.11% | -0.11% | 3370 | 3384 | 3384 | -0.41% | -0.41% | 3200 | 3212 | 3212 | -0.37% | -0.37% |
| canterbury/lcet10.txt | 158451 | 158524 | 158524 | -0.05% | -0.05% | 148574 | 148564 | 148564 | +0.01% | +0.01% | 141027 | 141028 | 141028 | -0.00% | -0.00% | 140526 | 140402 | 140402 | +0.09% | +0.09% |
| canterbury/alice29.txt | 59650 | 59661 | 59661 | -0.02% | -0.02% | 57363 | 57352 | 57352 | +0.02% | +0.02% | 56984 | 56974 | 56974 | +0.02% | +0.02% | 54195 | 54188 | 54286 | +0.01% | -0.17% |
| canterbury/grammar.lsp | 1344 | 1341 | 1341 | +0.22% | +0.22% | 1334 | 1333 | 1333 | +0.08% | +0.08% | 1303 | 1295 | 1295 | +0.62% | +0.62% | 1263 | 1258 | 1258 | +0.40% | +0.40% |
| canterbury/kennedy.xls | 115586 | 115395 | 115395 | +0.17% | +0.17% | 111373 | 112242 | 112242 | -0.77% | -0.77% | 112060 | 111831 | 111831 | +0.20% | +0.20% | 111064 | 110925 | 110925 | +0.13% | +0.13% |
| canterbury/asyoulik.txt | 54524 | 54516 | 54516 | +0.01% | +0.01% | 51866 | 51858 | 51858 | +0.02% | +0.02% | 50336 | 50328 | 50328 | +0.02% | +0.02% | 51156 | 51146 | 51146 | +0.02% | +0.02% |
| canterbury/plrabn12.txt | 217869 | 217845 | 217845 | +0.01% | +0.01% | 198499 | 198467 | 198467 | +0.02% | +0.02% | 191716 | 191688 | 191688 | +0.01% | +0.01% | 189649 | 189624 | 189624 | +0.01% | +0.01% |
| silesia total | 73350330 | 73276937 | 73276937 | +0.10% | +0.10% | 69409877 | 69392937 | 69392937 | +0.02% | +0.02% | 66370602 | 66216569 | 66216569 | +0.23% | +0.23% | 65159456 | 65060346 | 65060346 | +0.15% | +0.15% |
| canterbury total | 686930 | 686824 | 686824 | +0.02% | +0.02% | 649279 | 650125 | 650125 | -0.13% | -0.13% | 634725 | 634602 | 634602 | +0.02% | +0.02% | 628801 | 628626 | 628724 | +0.03% | +0.01% |

### Levels 5–8

| Corpus / file | gaato 5 | HC 5 | default 5 | Δ HC | Δ default | gaato 6 | HC 6 | default 6 | Δ HC | Δ default | gaato 7 | HC 7 | default 7 | Δ HC | Δ default | gaato 8 | HC 8 | default 8 | Δ HC | Δ default |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| silesia/mr | 3387593 | 3382779 | 3371721 | +0.14% | +0.47% | 3408192 | 3403515 | 3388785 | +0.14% | +0.57% | 3360956 | 3357935 | 3347832 | +0.09% | +0.39% | 3352463 | 3346948 | 3335624 | +0.16% | +0.50% |
| silesia/nci | 2647058 | 2657009 | 2583327 | -0.37% | +2.47% | 2477064 | 2491427 | 2431116 | -0.58% | +1.89% | 2386372 | 2399100 | 2357794 | -0.53% | +1.21% | 2307676 | 2319298 | 2282118 | -0.50% | +1.12% |
| silesia/sao | 5293556 | 5292597 | 5305357 | +0.02% | -0.22% | 5262099 | 5261586 | 5272387 | +0.01% | -0.20% | 5226683 | 5226052 | 5232513 | +0.01% | -0.11% | 5231357 | 5230833 | 5237417 | +0.01% | -0.12% |
| silesia/xml | 586127 | 584916 | 575134 | +0.21% | +1.91% | 556442 | 555116 | 546825 | +0.24% | +1.76% | 535397 | 534307 | 531025 | +0.20% | +0.82% | 521673 | 520585 | 517820 | +0.21% | +0.74% |
| silesia/osdb | 3444664 | 3448415 | 3431228 | -0.11% | +0.39% | 3399628 | 3402432 | 3398186 | -0.08% | +0.04% | 3349829 | 3354483 | 3359176 | -0.14% | -0.28% | 3341292 | 3344147 | 3350912 | -0.09% | -0.29% |
| silesia/samba | 4757599 | 4765974 | 4727107 | -0.18% | +0.65% | 4606784 | 4617166 | 4578988 | -0.22% | +0.61% | 4541024 | 4550784 | 4518027 | -0.21% | +0.51% | 4469346 | 4466444 | 4435246 | +0.06% | +0.77% |
| silesia/x-ray | 5491825 | 5492660 | 5557222 | -0.02% | -1.18% | 5485670 | 5486528 | 5552347 | -0.02% | -1.20% | 5395158 | 5396659 | 5435848 | -0.03% | -0.75% | 5398012 | 5398134 | 5436974 | -0.00% | -0.72% |
| silesia/dickens | 3542463 | 3543504 | 3531666 | -0.03% | +0.31% | 3433761 | 3435357 | 3421208 | -0.05% | +0.37% | 3348562 | 3350795 | 3350065 | -0.07% | -0.04% | 3313832 | 3314753 | 3311445 | -0.03% | +0.07% |
| silesia/mozilla | 17867585 | 17721565 | 17697993 | +0.82% | +0.96% | 17358903 | 17233327 | 17230352 | +0.73% | +0.75% | 17216963 | 17101257 | 17073567 | +0.68% | +0.84% | 17084267 | 16945455 | 16918320 | +0.82% | +0.98% |
| silesia/ooffice | 2976836 | 2964007 | 2973517 | +0.43% | +0.11% | 2930818 | 2918438 | 2931752 | +0.42% | -0.03% | 2900484 | 2888533 | 2892718 | +0.41% | +0.27% | 2888183 | 2875983 | 2880633 | +0.42% | +0.26% |
| silesia/reymont | 1889495 | 1891948 | 1866705 | -0.13% | +1.22% | 1793598 | 1795704 | 1774232 | -0.12% | +1.09% | 1729367 | 1731302 | 1719983 | -0.11% | +0.55% | 1690898 | 1693221 | 1680211 | -0.14% | +0.64% |
| silesia/webster | 11348814 | 11361204 | 11231585 | -0.11% | +1.04% | 10932364 | 10943799 | 10825886 | -0.10% | +0.98% | 10647167 | 10662025 | 10582301 | -0.14% | +0.61% | 10511958 | 10518489 | 10433315 | -0.06% | +0.75% |
| canterbury/sum | 12887 | 12897 | 12907 | -0.08% | -0.15% | 12561 | 12573 | 12584 | -0.10% | -0.18% | 12543 | 12554 | 12569 | -0.09% | -0.21% | 12507 | 12524 | 12538 | -0.14% | -0.25% |
| canterbury/ptt5 | 53260 | 53418 | 53484 | -0.30% | -0.42% | 51067 | 51347 | 51374 | -0.55% | -0.60% | 51051 | 51317 | 51342 | -0.52% | -0.57% | 49625 | 49930 | 49960 | -0.61% | -0.67% |
| canterbury/cp.html | 8152 | 8156 | 8159 | -0.05% | -0.09% | 8018 | 8020 | 8025 | -0.02% | -0.09% | 7994 | 7996 | 8002 | -0.03% | -0.10% | 7964 | 7968 | 7974 | -0.05% | -0.13% |
| canterbury/xargs.1 | 1755 | 1754 | 1754 | +0.06% | +0.06% | 1754 | 1752 | 1752 | +0.11% | +0.11% | 1753 | 1752 | 1752 | +0.06% | +0.06% | 1753 | 1752 | 1752 | +0.06% | +0.06% |
| canterbury/fields.c | 3164 | 3175 | 3175 | -0.35% | -0.35% | 3133 | 3141 | 3141 | -0.25% | -0.25% | 3125 | 3132 | 3132 | -0.22% | -0.22% | 3125 | 3131 | 3131 | -0.19% | -0.19% |
| canterbury/lcet10.txt | 136232 | 136246 | 136241 | -0.01% | -0.01% | 132673 | 132548 | 132588 | +0.09% | +0.06% | 131048 | 131052 | 131307 | -0.00% | -0.20% | 129939 | 129849 | 130052 | +0.07% | -0.09% |
| canterbury/alice29.txt | 53270 | 53255 | 53376 | +0.03% | -0.20% | 53085 | 53077 | 53115 | +0.02% | -0.06% | 53052 | 53042 | 53199 | +0.02% | -0.28% | 52578 | 52580 | 52714 | -0.00% | -0.26% |
| canterbury/grammar.lsp | 1253 | 1249 | 1249 | +0.32% | +0.32% | 1252 | 1247 | 1247 | +0.40% | +0.40% | 1251 | 1246 | 1246 | +0.40% | +0.40% | 1251 | 1246 | 1246 | +0.40% | +0.40% |
| canterbury/kennedy.xls | 110637 | 111216 | 111251 | -0.52% | -0.55% | 106003 | 107980 | 107919 | -1.83% | -1.78% | 104340 | 106426 | 106592 | -1.96% | -2.11% | 109789 | 110926 | 111057 | -1.03% | -1.14% |
| canterbury/asyoulik.txt | 49732 | 49729 | 49779 | +0.01% | -0.09% | 48506 | 48504 | 48579 | +0.00% | -0.15% | 48093 | 48093 | 48144 | +0.00% | -0.11% | 47670 | 47665 | 47792 | +0.01% | -0.26% |
| canterbury/plrabn12.txt | 186054 | 186015 | 186221 | +0.02% | -0.09% | 182088 | 182071 | 182274 | +0.01% | -0.10% | 180223 | 180206 | 180675 | +0.01% | -0.25% | 179003 | 178988 | 179367 | +0.01% | -0.20% |
| silesia total | 63233615 | 63106578 | 62852562 | +0.20% | +0.61% | 61645323 | 61544395 | 61352064 | +0.16% | +0.48% | 60637962 | 60553232 | 60400849 | +0.14% | +0.39% | 60110957 | 59974290 | 59820035 | +0.23% | +0.49% |
| canterbury total | 616396 | 617110 | 617596 | -0.12% | -0.19% | 600140 | 602260 | 602598 | -0.35% | -0.41% | 594473 | 596816 | 597960 | -0.39% | -0.58% | 595204 | 596559 | 597583 | -0.23% | -0.40% |

### Levels 9–12

| Corpus / file | gaato 9 | HC 9 | default 9 | Δ HC | Δ default | gaato 10 | HC 10 | default 10 | Δ HC | Δ default | gaato 11 | HC 11 | default 11 | Δ HC | Δ default | gaato 12 | HC 12 | default 12 | Δ HC | Δ default |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| silesia/mr | 3332990 | 3325572 | 3317712 | +0.22% | +0.46% | 3298543 | 3291457 | 3287133 | +0.22% | +0.35% | 3284172 | 3277572 | 3271230 | +0.20% | +0.40% | 3272592 | 3266079 | 3268705 | +0.20% | +0.12% |
| silesia/nci | 2271712 | 2280704 | 2247493 | -0.39% | +1.08% | 2182937 | 2191056 | 2167618 | -0.37% | +0.71% | 2133876 | 2141417 | 2106557 | -0.35% | +1.30% | 2095009 | 2103623 | 2105187 | -0.41% | -0.48% |
| silesia/sao | 5212019 | 5211585 | 5215726 | +0.01% | -0.07% | 5201084 | 5200747 | 5202036 | +0.01% | -0.02% | 5199513 | 5199126 | 5200433 | +0.01% | -0.02% | 5197920 | 5197735 | 5198861 | +0.00% | -0.02% |
| silesia/xml | 516959 | 516015 | 517101 | +0.18% | -0.03% | 506200 | 505491 | 505784 | +0.14% | +0.08% | 498663 | 498078 | 498252 | +0.12% | +0.08% | 498662 | 498062 | 498099 | +0.12% | +0.11% |
| silesia/osdb | 3335675 | 3337216 | 3342533 | -0.05% | -0.21% | 3279719 | 3281888 | 3286549 | -0.07% | -0.21% | 3216667 | 3217839 | 3225629 | -0.04% | -0.28% | 3215682 | 3216619 | 3221782 | -0.03% | -0.19% |
| silesia/samba | 4393056 | 4394559 | 4362741 | -0.03% | +0.69% | 4337584 | 4340518 | 4322821 | -0.07% | +0.34% | 4323333 | 4326496 | 4302428 | -0.07% | +0.49% | 4281828 | 4291274 | 4299325 | -0.22% | -0.41% |
| silesia/x-ray | 5346170 | 5345776 | 5361360 | +0.01% | -0.28% | 5319393 | 5318872 | 5321153 | +0.01% | -0.03% | 5318873 | 5317475 | 5316375 | +0.03% | +0.05% | 5310980 | 5310638 | 5311999 | +0.01% | -0.02% |
| silesia/dickens | 3281524 | 3281245 | 3282528 | +0.01% | -0.03% | 3215179 | 3214923 | 3217628 | +0.01% | -0.08% | 3176929 | 3176695 | 3175501 | +0.01% | +0.04% | 3161312 | 3160941 | 3168795 | +0.01% | -0.24% |
| silesia/mozilla | 16891538 | 16760484 | 16735963 | +0.78% | +0.93% | 16791632 | 16667318 | 16652199 | +0.75% | +0.84% | 16765412 | 16642207 | 16621465 | +0.74% | +0.87% | 16718952 | 16603224 | 16613591 | +0.70% | +0.63% |
| silesia/ooffice | 2866312 | 2854493 | 2856869 | +0.41% | +0.33% | 2851045 | 2839119 | 2839771 | +0.42% | +0.40% | 2847254 | 2835381 | 2834194 | +0.42% | +0.46% | 2842163 | 2830327 | 2832083 | +0.42% | +0.36% |
| silesia/reymont | 1673027 | 1675553 | 1670543 | -0.15% | +0.15% | 1618170 | 1620617 | 1619324 | -0.15% | -0.07% | 1580745 | 1582449 | 1579346 | -0.11% | +0.09% | 1572642 | 1574748 | 1577095 | -0.13% | -0.28% |
| silesia/webster | 10337636 | 10343566 | 10271610 | -0.06% | +0.64% | 10101099 | 10111731 | 10074530 | -0.11% | +0.26% | 10002432 | 10012523 | 9955035 | -0.10% | +0.48% | 9897958 | 9919874 | 9938414 | -0.22% | -0.41% |
| canterbury/sum | 12495 | 12511 | 12518 | -0.13% | -0.18% | 12493 | 12505 | 12515 | -0.10% | -0.18% | 12495 | 12491 | 12491 | +0.03% | +0.03% | 12492 | 12485 | 12485 | +0.06% | +0.06% |
| canterbury/ptt5 | 49625 | 49930 | 49960 | -0.61% | -0.67% | 49617 | 49918 | 49953 | -0.60% | -0.67% | 49650 | 49944 | 49973 | -0.59% | -0.65% | 49650 | 49944 | 49973 | -0.59% | -0.65% |
| canterbury/cp.html | 7923 | 7925 | 7933 | -0.03% | -0.13% | 7904 | 7907 | 7920 | -0.04% | -0.20% | 7923 | 7904 | 7904 | +0.24% | +0.24% | 7900 | 7899 | 7899 | +0.01% | +0.01% |
| canterbury/xargs.1 | 1753 | 1751 | 1751 | +0.11% | +0.11% | 1753 | 1751 | 1751 | +0.11% | +0.11% | 1754 | 1745 | 1745 | +0.52% | +0.52% | 1754 | 1739 | 1739 | +0.86% | +0.86% |
| canterbury/fields.c | 3130 | 3126 | 3126 | +0.13% | +0.13% | 3125 | 3126 | 3126 | -0.03% | -0.03% | 3147 | 3095 | 3095 | +1.68% | +1.68% | 3133 | 3041 | 3041 | +3.03% | +3.03% |
| canterbury/lcet10.txt | 129939 | 129849 | 130052 | +0.07% | -0.09% | 129153 | 129069 | 129223 | +0.07% | -0.05% | 128714 | 128625 | 128720 | +0.07% | -0.00% | 128714 | 128625 | 128720 | +0.07% | -0.00% |
| canterbury/alice29.txt | 52137 | 52130 | 52192 | +0.01% | -0.11% | 51876 | 51869 | 51898 | +0.01% | -0.04% | 52137 | 51495 | 51495 | +1.25% | +1.25% | 51733 | 51496 | 51496 | +0.46% | +0.46% |
| canterbury/grammar.lsp | 1251 | 1245 | 1245 | +0.48% | +0.48% | 1251 | 1245 | 1245 | +0.48% | +0.48% | 1254 | 1237 | 1237 | +1.37% | +1.37% | 1252 | 1228 | 1228 | +1.95% | +1.95% |
| canterbury/kennedy.xls | 109789 | 110926 | 111062 | -1.03% | -1.15% | 109856 | 110963 | 111002 | -1.00% | -1.03% | 110049 | 111177 | 111253 | -1.01% | -1.08% | 110049 | 111177 | 111253 | -1.01% | -1.08% |
| canterbury/asyoulik.txt | 47446 | 47439 | 47546 | +0.01% | -0.21% | 47311 | 47309 | 47365 | +0.00% | -0.11% | 47415 | 47083 | 47083 | +0.71% | +0.71% | 47241 | 47047 | 47047 | +0.41% | +0.41% |
| canterbury/plrabn12.txt | 179003 | 178988 | 179367 | +0.01% | -0.20% | 178023 | 177997 | 178268 | +0.01% | -0.14% | 177351 | 177327 | 177491 | +0.01% | -0.08% | 177351 | 177327 | 177491 | +0.01% | -0.08% |
| silesia total | 59458618 | 59326768 | 59182179 | +0.22% | +0.47% | 58702585 | 58583737 | 58496546 | +0.20% | +0.35% | 58347869 | 58227258 | 58086445 | +0.21% | +0.45% | 58065700 | 57973144 | 58033936 | +0.16% | +0.05% |
| canterbury total | 594491 | 595820 | 596752 | -0.22% | -0.38% | 592362 | 593659 | 594266 | -0.22% | -0.32% | 591889 | 592123 | 592487 | -0.04% | -0.10% | 591269 | 592008 | 592372 | -0.12% | -0.19% |

### Outlier investigation

Every corpus total is within 1% under both reference configurations.
Against HC, Silesia deltas range from +0.02% to +0.23%; Canterbury
ranges from -0.39% to +0.03%. Against default, the largest corpus delta
is Silesia level five at +0.61%, consistent with the different row search.

The only file outside an absolute 3% difference is `fields.c` at level
twelve: 3,133 bytes versus 3,041 (+3.03%) under either reference mode.
Its 11,150-byte source selects the Btopt row: adjusted
window/chain/hash/search/minMatch/target = 14/15/14/4/3/24. The
documented mapping uses lazy2 with those numbers. Forcing the reference
to lazy2 with
`zstd -12 --no-row-match-finder --zstd=strat=5 --check -c -q fields.c`
gives 3,141 bytes; adding `mml=4` gives the same 3,141. This isolates the
3% gap to the out-of-scope optimal parser rather than a missing HC lazy2
gain rule. The remaining 8-byte (-0.25%) difference to forced lazy2 was
not attributed byte for byte: entropy/offset selection and forcing a
strategy can differ, including the chain adjustment cycle bit.
No corpus-specific parameters or search cap were added.

The old level-four `fields.c`, `grammar.lsp` and `alice29.txt` outliers
close after selecting their actual greedy rows. The tables preserve the
ordinary CLI comparison as well as HC, so choosing HC does not conceal
a regression relative to the default executable.

## Known-size parameter adjustment

`params_for` applies the no-dictionary part of
[ZSTD_adjustCParams_internal, v1.5.7](https://github.com/facebook/zstd/blob/v1.5.7/lib/compress/zstd_compress.c#L1473)
after selecting a size-class row, before mapping tree rows to lazy2.
For sizes at most 2^30, shrink windowLog to the rounded-up
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
exclusions are not used; tree mappings retain the adjusted numeric row.
No searchLog, minMatch or targetLength adjustment applies here.
Tests pin window/chain/hash rows for ten sizes at every level, including
tiny sources and tree strategies, plus the size-class and 2^30 boundaries.
For example, level three at 1,000 bytes now uses 10/10/11 instead of
10/14/15. Table allocations only shrink from each unknown-size row.

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

## Speed

Encoding speed, measured on an Intel Core i5-10400F pinned to one CPU
(`taskset -c 2`), with MoonBit 0.10.20 (GCC for native, moonrun for Wasm
and Wasm GC, Node 26 for JS), through codec_bench's "zstd encode": the
bench text (512 KiB) and binary (128 KiB), their size unknown to the
encoder, so the largest parameter class. The reference is zstd 1.5.7's
`zstd -b<level>` on the same files.

### Starting point

| Input, level | Native | Wasm | Wasm GC | JS | zstd 1.5.7 |
|---|---:|---:|---:|---:|---:|
| text, 1 | 11.85 ms (44 MB/s) | 40.00 ms | 13.67 ms | 94.08 ms | 303.6 MB/s |
| text, 3 | 12.98 ms (40 MB/s) | 42.53 ms | 14.94 ms | 117.13 ms | 228.5 MB/s |
| text, 5 | 22.38 ms (23 MB/s) | 70.91 ms | 21.89 ms | 149.87 ms | 107.6 MB/s |
| text, 8 | 47.62 ms (11 MB/s) | 125.83 ms | 49.46 ms | 206.25 ms | 46.8 MB/s |
| text, 12 | 105.01 ms (5.0 MB/s) | 192.79 ms | 105.26 ms | 306.97 ms | 24.8 MB/s |
| binary, 1 | 1.55 ms (85 MB/s) | 4.12 ms | 1.82 ms | 9.80 ms | 724.8 MB/s |
| binary, 3 | 4.28 ms (31 MB/s) | 12.09 ms | 4.95 ms | 47.68 ms | 185.2 MB/s |
| binary, 12 | 21.90 ms (6.0 MB/s) | 23.51 ms | 20.41 ms | 104.12 ms | 36.5 MB/s |

Where native time goes (`perf record -e cycles:u`, the text, share of
samples by function):

| Level | Largest shares |
|---|---|
| 1 | block loop with the inlined fast search 27.3%, `Fast::hash_at` 15.6%, allocation (`malloc`, `free`, `moonbit_drop_object`) 15.6%, `Fast::length` 9.3%, `Block::add` 8.0%, `BitPacker::write` 8.0%, `CTable::encode` 4.9% |
| 3 | block loop with the inlined dfast search 35.8%, allocation 16.6%, `Block::add` 8.1%, `Dfast::length` 8.0%, `BitPacker::write` 6.5%, `Dfast::hash_at` 5.8% |
| 5 | `Lazy::search` 37.2%, `Lazy::hash_at` 13.9%, block loop 10.5%, allocation 13.0%, `Lazy::length` 5.2% |
| 12 | `Lazy::search` 78.5%, `moonbit_make_int32_array` 4.0%, `Lazy::length` 3.8%, `Lazy::hash_at` 3.5% |

The allocation comes from functions returning tuples, which native
MoonBit boxes on the heap unless inlined: `offset_code` (once or more a
sequence) and `Lazy::search` (once a search). Wasm runs about three times
as long as native and Wasm GC because each bounds-checked array access
there calls two out-of-line helpers (the length and the range check).

### After removing allocation from the encoding path

Same command and inputs, targets run one at a time:

```sh
MOON_CC=cc taskset -c 2 moon bench --release --target native -p gaato/codec_bench -f bench_test.mbt -i 3
# Repeat with --target wasm, wasm-gc and js.
```

| Input, level | Native | Wasm | Wasm GC | JS |
|---|---:|---:|---:|---:|
| text, 1 | 9.84 ms | 30.05 ms | 13.21 ms | 96.15 ms |
| text, 3 | 10.31 ms | 33.01 ms | 14.23 ms | 118.43 ms |
| text, 5 | 18.89 ms | 56.58 ms | 21.49 ms | 148.08 ms |
| text, 8 | 42.42 ms | 101.87 ms | 50.69 ms | 210.29 ms |
| text, 12 | 102.73 ms | 175.39 ms | 116.31 ms | 311.11 ms |
| binary, 1 | 1.53 ms | 4.08 ms | 1.76 ms | 9.72 ms |
| binary, 3 | 3.96 ms | 11.38 ms | 4.85 ms | 48.54 ms |
| binary, 12 | 20.53 ms | 20.57 ms | 28.02 ms | 107.37 ms |

The first Wasm GC run appeared slower than the starting point at level
twelve. To check drift, the unchanged parent sources were measured again
for Wasm GC and JS, each followed immediately by the changed sources
(the numbers above). These refreshed baselines were:

| Input, level | Wasm GC before | JS before |
|---|---:|---:|
| text, 1 | 13.75 ms | 98.33 ms |
| text, 3 | 15.01 ms | 114.00 ms |
| text, 5 | 22.27 ms | 150.44 ms |
| text, 8 | 52.09 ms | 210.96 ms |
| text, 12 | 118.67 ms | 316.88 ms |
| binary, 1 | 1.78 ms | 9.78 ms |
| binary, 3 | 4.88 ms | 47.60 ms |
| binary, 12 | 29.80 ms | 108.18 ms |

Native text improves by 2–21%, Wasm by 9–25%; Wasm GC improves against
the refreshed baseline. JS is roughly unchanged: its text level-three
mean is 3.9% higher, with standard deviation 10.88 ms after versus
3.42 ms before, and binary level three is 2.0% higher with 2.52 ms
versus 1.08 ms deviation. These runs do not establish a JS speedup or
a repeatable regression. The older level-twelve Wasm GC times should
not be used to attribute a regression to this change.

`offset_code` and `offset_extra` now return separate scalars: `#inline`
alone still left a boxed tuple in the generated C with this toolchain.
`Lazy::search` writes its length and distance into the finder. Another
per-sequence allocation was `Repeats::encode`'s trial `Repeats` object
and three-element array: it now saves the original history in scalars
and restores it after each unsuccessful resolver trial, keeping the
same resolver and repeat priority. Four-stream Huffman jump-table
entries are written as they are counted, without a temporary array.
Literals plans and their kinds are value types, and rebasing the two
match tables uses separate loops instead of an array of tables.

The release native bench C was inspected after:

```sh
MOON_CC=cc moon bench --release --target native -p gaato/codec_bench -f bench_test.mbt -i 3 --build-only
rg -n 'moonbit_malloc|moonbit_make_' _build/native/release/bench/gaato/codec_bench/codec_bench.blackbox_test.c
```

Following calls from `Encoder::encode_block` reaches 79 generated
functions. None calls `moonbit_malloc`. The nine remaining `moonbit_make_*`
sites all grow retained buffers only when capacity is insufficient:
one history byte buffer in each of Fast, Dfast and Lazy; Block's gathered
literals and three sequence arrays; the accepted sequence copy; and
`BitPacker::reserve`. No allocation remains per sequence or search, or
per block once those capacities suffice. Encoder construction still
allocates and initializes the parameter-selected hash and chain tables;
the large level-twelve row's 48 MiB of position tables is unchanged.
The reported array bounds and compression-size tables are unchanged.
The size comparison was rerun: all 276 published corpus counts match,
and all 300 frames (including the two bench inputs at every level)
decode back with gaato and `zstd -d`.

A `perf record -e cycles:u -F 4000` run over all eight encoding benchmarks
recorded 43,015 samples: `moonbit_drop_object` is 0.03%, `malloc` 0.02%
and `cfree` 0.01%. `moonbit_make_int32_array` still accounts for 3.68%
in this combined run, which includes constructing a fresh encoder for
every iteration and growing its buffers; it is not a remaining
per-sequence scratch allocation. These combined shares are not directly
comparable with the separate per-level starting-point profiles.

### After widening matcher reads

Native and Wasm read each hash in one unchecked little-endian eight-byte
load. Construction selects the hash multiplier and input shift for the clamped width;
there is no width branch in the hot hash calculation. Shifting the low
four bytes into the high half before multiplication reproduces hash4's
32-bit overflow exactly; widths five through eight retain the reference
shift and multiplier. Table reads/writes, chain links, backward extension
and literal reads use unchecked accesses with local range arguments on
these targets. Lazy's four-byte tail rejection uses one 32-bit load.
XXH64 also uses unchecked 32/64-bit loads after its stripe/tail guards.
No read consumes bytes beyond the valid data, even when capacity is larger.

Two match-length loops were compared with the same hash and table changes:
eight-byte XOR plus `ctz / 8`, and sixteen-byte `i8x16_eq` plus
`i8x16_bitmask`, followed by an eight-byte comparison and individual
remaining bytes. The SIMD code is confined to `internal/match_length_fast`.
In MoonBit 0.10.20's `moonbit_simd.h`, equality and bitmask lower to
`pcmpeqb` and `pmovmskb` on SSE2. NEON equality is `vceqq_u8`; its bitmask
uses a shift, three shift/accumulates and two lane extractions. These
timings are x86 measurements, not arm64 performance claims.

Same pinned-CPU command as above, targets and variants run separately.
The native comparison below is the second pair: the first SIMD run had
1.90/6.11 ms standard deviations at text levels eight/twelve, so both
native variants were repeated. All values are means in milliseconds.

| Input, level | Native, 8-byte | Native, 16-byte | Wasm, 8-byte | Wasm, 16-byte |
|---|---:|---:|---:|---:|
| text, 1 | 7.61 | 7.46 | 22.91 | 22.19 |
| text, 3 | 7.48 | 7.45 | 22.36 | 22.38 |
| text, 5 | 13.70 | 13.39 | 32.50 | 31.59 |
| text, 8 | 30.55 | 28.29 | 53.96 | 53.03 |
| text, 12 | 78.31 | 77.01 | 101.84 | 100.43 |
| binary, 1 | 1.32 | 1.32 | 3.42 | 3.41 |
| binary, 3 | 3.05 | 3.05 | 7.64 | 7.41 |
| binary, 12 | 17.78 | 18.08 | 13.69 | 13.77 |

The sixteen-byte loop is retained on native and Wasm: it wins on most
text cases, including the faster levels, with broadly similar binary
times. It is not faster on every input: native binary level twelve is
1.7% slower than eight-byte, and Wasm text level three and binary level
twelve are essentially tied. The native text-level-eight repeat still
has 2.50 ms deviation in the eight-byte run; its full mean difference
should not be attributed to SIMD alone.

The final four-target run also moves the input-shift calculation to
construction. Compared with the preceding allocation table:

| Input, level | Native | Wasm | Wasm GC | JS |
|---|---:|---:|---:|---:|
| text, 1 | 7.41 ms | 22.50 ms | 13.70 ms | 93.69 ms |
| text, 3 | 7.49 ms | 22.09 ms | 12.18 ms | 115.23 ms |
| text, 5 | 13.30 ms | 31.39 ms | 21.20 ms | 146.17 ms |
| text, 8 | 27.98 ms | 52.78 ms | 51.95 ms | 209.04 ms |
| text, 12 | 76.23 ms | 101.40 ms | 119.07 ms | 325.03 ms |
| binary, 1 | 1.32 ms | 3.43 ms | 1.62 ms | 9.72 ms |
| binary, 3 | 3.09 ms | 7.50 ms | 4.77 ms | 48.29 ms |
| binary, 12 | 17.78 ms | 14.21 ms | 28.62 ms | 108.76 ms |

Native improves by 13–34% and Wasm by 16–48% against the preceding table.
JS and Wasm GC retain checked byte loads, the original width-dependent
hash formulas and byte-at-a-time lengths. Trying the preselected hash
multiplier on these targets did not establish a consistent improvement;
it was reverted. Their original object fields and construction are also
retained, without a wide-hash multiplier field. Neither eight-byte BigInt
arithmetic nor SIMD runs in their matcher loops.

The unchanged parent sources were also rerun for these two targets,
restoring the edited files afterwards without changing Jujutsu history:

| Input, level | Wasm GC refreshed before | JS refreshed before |
|---|---:|---:|
| text, 1 | 13.24 ms | 92.51 ms |
| text, 3 | 14.33 ms | 117.52 ms |
| text, 5 | 21.37 ms | 147.77 ms |
| text, 8 | 50.91 ms | 211.50 ms |
| text, 12 | 118.26 ms | 315.70 ms |
| binary, 1 | 1.77 ms | 9.68 ms |
| binary, 3 | 4.82 ms | 47.26 ms |
| binary, 12 | 27.88 ms | 106.37 ms |

Some retained-path means still exceed both earlier tables: relative to the
allocation table, the largest increases are Wasm GC text level one (3.7%)
and JS text level twelve (4.5%). JS level twelve's final deviation is
25.25 ms, compared with the 13.92 ms difference; Wasm GC's final text
level-one deviation is 0.27 ms. These numbers do not establish uniformly
unchanged speed. The original checked paths are retained rather than
extending wide reads to them; no JS/Wasm GC speedup is claimed.

The 276 published compression counts were rechecked without changing a
byte; all 300 corpus/bench frames round-trip through gaato and `zstd -d`.
Existing SHA-256 pins are unchanged. Additional pins were established with
the original byte-wise implementation for exact-end, block-boundary and
short-input fixtures, then checked on all four targets. The external
crosscheck additionally decodes these inputs and 1 KiB sliding-window
frames from all three match finders with both `zstd -d` and Node.

### After sharing input and match history

Fast, double-fast and lazy now use `internal/match/History`: one buffer
for retained history and the unfinished cutter block. The encoder appends
caller input directly there. Checksum, raw/RLE fallback and match parsing
read that block in place; gathered literals keep their existing sequence
buffer. There is no separate encoder input allocation or block-to-finder
copy. A whole cutter block is reserved before its first byte, so neither
input step sizes nor output slice sizes decide when history slides.

The buffer grows up to window + slack + min(window, 128 KiB). Only when
the next whole block would exceed that limit does one overlapping
`FixedArray::unsafe_blit` retain the window, followed by one rebase of each
position table. Lazy adjusts its chain-ring bias and insertion cursor by
the same cut. Logical per-block floors still limit backward extension,
repeat eligibility and lazy insertion; delaying physical eviction cannot
change the original parser decisions.

The slack comparison uses `window_bench_test.mbt`: 24 copies of the bench
text (12 MiB), with each 257th byte XORed with the copy number. Inputs
are constructed before timing; every timed iteration creates a fresh
unknown-size encoder. Same CPU and toolchain as above, targets and
variants run individually. Times below are means in milliseconds.

| Slack | Native l1 | Native l3 | Native l12 | Wasm l1 | Wasm l3 | Wasm l12 |
|---|---:|---:|---:|---:|---:|---:|
| window / 4 | 20.35 | 25.22 | 393.83 | 78.29 | 83.49 | 650.81 |
| window / 2 | 20.48 | 23.54 | 336.57 | 74.42 | 77.73 | 547.14 |
| window | 20.30 | 24.58 | 329.05 | 78.50 | 79.63 | 486.27 |

| Slack | Extra history at l1 / l3 / l12 | Maximum encoder bound |
|---|---|---:|
| window / 4 | 128 KiB / 512 KiB / 1 MiB | 57,831,328 bytes |
| window / 2 | 256 KiB / 1 MiB / 2 MiB | 58,879,904 bytes |
| window | 512 KiB / 2 MiB / 4 MiB | 60,977,056 bytes |

One window of slack is retained: it moves at most about one retained byte
per input byte after growth, and level twelve is 11.1% faster on Wasm
than half a window, for another 2 MiB at that row. Native level twelve
improves 2.2%. Half a window is slightly faster at level three; the full
window is chosen for its larger-table case, not a uniform speed win.
The full-window Wasm l1/l3 deviations were 6.33/8.12 ms, so their small
differences are not reliable advantages for either size.

```sh
MOON_CC=cc taskset -c 2 moon bench --release --target native -p gaato/codec_bench -f window_bench_test.mbt
# Repeat with --target wasm. For the slack comparison, only History::limit's
# second window term was changed to window >> 2 or window >> 1.
```

| 12 MiB varied text | Native before | Native after | Wasm before | Wasm after |
|---|---:|---:|---:|---:|
| level 1 | 53.54 | 20.30 | 387.75 | 78.50 |
| level 3 | 135.65 | 24.58 | 1,400 | 79.63 |
| level 12 | 1,160 | 329.05 | 8,230 | 486.27 |

These inputs exceed twice the largest 4 MiB window. The shorter standard
benchmarks below mostly measure construction and parsing, since their
512/128 KiB inputs do not fill the large windows. The maximum reported
encoder bound changes from 56,913,824 to 60,977,056 bytes: add 4 MiB slack
and remove the separate 128 KiB input buffer. RESOURCE_BOUNDS.md and its
full-capacity tests derive the same bound, also used by conformance.

The standard codec_bench "zstd encode" run, before and after, in
milliseconds (same command as the earlier tables):

| Input, level | Native before → after | Wasm before → after | Wasm GC before → after | JS before → after |
|---|---:|---:|---:|---:|
| text, 1 | 7.48 → 7.65 | 22.32 → 22.42 | 13.73 → 14.08 | 93.21 → 92.26 |
| text, 3 | 7.39 → 7.52 | 21.98 → 22.13 | 12.31 → 12.37 | 114.04 → 116.91 |
| text, 5 | 13.55 → 13.56 | 31.21 → 32.08 | 21.16 → 20.76 | 146.54 → 144.30 |
| text, 8 | 28.82 → 28.48 | 50.91 → 53.73 | 51.55 → 51.48 | 219.82 → 214.03 |
| text, 12 | 73.81 → 77.65 | 98.21 → 102.56 | 118.34 → 117.86 | 320.38 → 316.78 |
| binary, 1 | 1.32 → 1.32 | 3.40 → 3.47 | 1.61 → 1.59 | 9.81 → 9.62 |
| binary, 3 | 3.01 → 3.12 | 7.45 → 7.37 | 4.70 → 4.66 | 47.41 → 49.68 |
| binary, 12 | 13.45 → 18.72 | 13.42 → 13.99 | 27.53 → 28.35 | 106.73 → 109.96 |

The first native binary level-twelve difference was not stable: repeating
the unchanged parent sources and then the changed sources gave
18.24 → 18.08 ms. The complete refreshed native pair was:

| Input, level | Refreshed native before | Refreshed native after |
|---|---:|---:|
| text, 1 | 7.41 | 7.64 |
| text, 3 | 7.39 | 7.54 |
| text, 5 | 13.41 | 13.53 |
| text, 8 | 28.23 | 28.72 |
| text, 12 | 76.74 | 77.49 |
| binary, 1 | 1.32 | 1.30 |
| binary, 3 | 3.01 | 3.06 |
| binary, 12 | 18.24 | 18.08 |

The short-input results do not establish a general speedup: native text
means in the refreshed pair rise by 0.9–3.1%, while the first Wasm text
level-eight mean rises by 5.5%. The large-input improvements come from
amortizing window and table movement; they do not remove all small-stream
costs of the shared representation.

Wasm GC was also repeated with unchanged parent sources followed by the
shared-history sources:

| Input, level | Refreshed Wasm GC before | Refreshed Wasm GC after |
|---|---:|---:|
| text, 1 | 13.55 | 14.19 |
| text, 3 | 12.11 | 12.33 |
| text, 5 | 21.14 | 21.02 |
| text, 8 | 51.33 | 52.28 |
| text, 12 | 116.61 | 120.72 |
| binary, 1 | 1.60 | 1.60 |
| binary, 3 | 4.66 | 4.65 |
| binary, 12 | 27.17 | 29.81 |

The binary level-twelve increase (9.7%, deviations 0.08/0.26 ms) remains
an open small-input performance cost. Capturing the checked hash buffer
locally was tried but did not consistently improve the measurements, so
the original checked hash expressions are retained. Unlike the earlier
wide-read work, shared input ownership necessarily changes the storage
representation on every target: restoring the old double-copy path on
Wasm GC would undo that part of this change. This is a deviation from the
performance plan's preference to keep slower checked targets unchanged;
no Wasm GC or JS speedup is claimed.

### After entropy coding without extra passes or copies

Literals and match length codes come from a table below 64 literals and
131 matched bytes, and above that from the highest set bit, as zstd's
`ZSTD_LLcode` and `ZSTD_MLcode` compute them, instead of scanning the
baseline table. A test compares both with the scan for every length from
0 to 131,072 on all four targets.

A block's literals are counted in one pass. Each step counts one byte of
each of the four Huffman streams into that stream's own table, which
spreads consecutive increments over four tables as zstd's
`HIST_count_parallel` does; native and Wasm read four bytes of each
stream at once. The block's counts are the sum of the four tables. Both
candidate codes' four-stream sizes and the jump table come from these
counts. Before, the literals were counted once for the block, once more
for each candidate code's streams, and three quarters of them again to
write the jump table. Blocks below 256 literals use one stream and keep
the single count. The four tables add 3,072 bytes to the literals writer.

The RLE block test compares eight bytes at a time on native and Wasm.
The finders gather literals in eight-byte copies there; the last partial
group is one eight-byte copy when both arrays have room past it (the
extra bytes land past the literals kept), otherwise byte by byte. JS and
Wasm GC keep the checked byte loops for both.

The sequence section is still written aside before the block. Its size
goes in the block header and decides between a compressed and a raw
block. That size cannot be computed exactly beforehand: how many bits
each FSE symbol takes depends on the state the symbols after it left,
so only encoding every sequence gives it. The table costs that choose the
modes are estimates rounded towards simpler tables. The accepted section
is now copied once, from its bit writer straight into the waiting output.
The separate 128 KiB section copy is gone.

`compress` steps the encoder into one array of the frame's bound: the
input, 3 bytes for each block and one more empty block, and 22 header and
checksum bytes. One copy trims it to the frame, or none when it fits
exactly; a test grows a too-small array. Before, each 64 KiB chunk was
copied to a `Bytes`, then into a `Buffer`, then out of it.

`reset` keeps the history buffer's capacity, as it already kept the
other buffers and tables. CONTRACT.md asks that a reset codec behave as a
new one with the same options: the output is the same, since a reset
drops every table position and matches compare only bytes below the
history's end. The `reset` tests compare frames with a new encoder's at
every level. `memory_usage` still counts the kept buffer, and the bound
is that of the encoder's own options, so a reset encoder stays within
it. The brotli encoder still releases its input buffer at `reset`.

MoonBit core 0.10.20 has a public bulk copy into a `MutArrayView`,
`MutArrayView::blit_from_array`. The shared bit writer's `drain` uses it
instead of a byte loop, for brotli's encoder as well.

The maximum encoder bound changes from 60,977,056 to 60,849,056 bytes:
the section copy's 131,072 bytes go, the four count tables' 3,072 come.

The same codec_bench "zstd encode" command as above, on each target
the parent sources and the changed sources alternately, twice
(the parent from an unchanged copy of the sources, without Jujutsu).
Means of the two runs on each side, in milliseconds:

| Input, level | Native before → after | Wasm before → after | Wasm GC before → after | JS before → after |
|---|---:|---:|---:|---:|
| text, 1 | 7.52 → 6.00 | 22.25 → 17.48 | 13.86 → 11.80 | 90.88 → 90.91 |
| text, 3 | 7.56 → 6.48 | 22.32 → 18.48 | 12.30 → 11.09 | 118.55 → 112.08 |
| text, 5 | 13.53 → 12.63 | 32.35 → 28.32 | 20.80 → 19.16 | 145.84 → 141.27 |
| text, 8 | 28.50 → 27.40 | 52.14 → 48.30 | 50.87 → 49.34 | 206.44 → 203.31 |
| text, 12 | 69.34 → 67.96 | 95.32 → 90.62 | 113.10 → 112.99 | 311.88 → 307.45 |
| binary, 1 | 1.31 → 1.06 | 3.46 → 2.25 | 1.62 → 1.65 | 9.70 → 8.95 |
| binary, 3 | 3.09 → 2.88 | 7.30 → 5.69 | 4.67 → 4.71 | 47.62 → 47.76 |
| binary, 12 | 11.23 → 11.32 | 13.09 → 11.88 | 24.64 → 24.52 | 109.62 → 106.88 |

Native text is 2–20% faster, most at the fast levels, where entropy
coding is a larger share; Wasm is 5–35% faster. Native binary level
twelve is not a change: its runs were 11.81 and 10.64 ms before and 10.27
and 12.38 ms after, the last with a 1.64 ms deviation. Wasm GC text is
up to 15% faster; its binary levels one and three are 1–2% slower, within
the spread between its before runs (1.60–1.64 and 4.63–4.76 ms). JS text
levels three to twelve and binary levels one and twelve are 1–8% faster;
text level one and binary level three are unchanged. A
first before run at the start of the session gave the same picture.

Sequences stay at 12 bytes each. Storing both lengths in one 32-bit word,
with the one length per block that may exceed 16 bits kept aside as zstd
does, was measured on native in the same session against the code above:

| Input, level | 12 bytes, two runs | 8 bytes |
|---|---:|---:|
| text, 1 | 6.02, 6.02 | 5.97 |
| text, 3 | 6.51, 6.52 | 6.42 |
| text, 5 | 12.53, 12.75 | 12.38 |
| text, 8 | 27.23, 27.84 | 27.38 |
| text, 12 | 67.82, 67.74 | 67.44 |
| binary, 1 | 1.05, 1.05 | 1.05 |
| binary, 3 | 2.74, 2.73 | 2.72 |
| binary, 12 | 10.29, 10.22 | 10.45 |

The differences are below 2% (at most 1.5% outside text level five,
whose first 12-byte run had a 0.54 ms deviation) and within run-to-run
spread, against a long-length case in every reader of the lengths and a
second representation in the tests. The packing is not done.

Unchanged: the 276 published compression counts (all 300 frames decode
with gaato and `zstd -d`), the SHA-256 pins on all four targets, and the
crosscheck (2,360 streams through `zstd -d` and Node).

### After writing bits eight bytes at a time

The shared bit writer (`internal/bits`, also brotli's) used to move every
whole byte into its buffer as soon as a write completed one: a capacity
check, then one checked store per byte. Now, except on JS, up to 31 bits
wait in its 64-bit accumulator, and the write that brings them to 32 or
more stores the accumulator into the buffer as one unchecked eight-byte
little-endian write and counts only the whole bytes, as zstd's
`BIT_addBits` and `BIT_flushBits` do. The bytes stored past the whole ones
are overwritten by the next store and never read. Instead of keeping eight
bytes of slack past the buffer's end, the store is taken only when eight
bytes of the buffer are left; nearer the end the whole bytes are written
one at a time, growing the buffer as before. Capacities therefore still
grow only by what is written, and every packer stays within the bounds
of RESOURCE_BOUNDS.md, which are unchanged. Counting, handing out, copying
and aligned byte writes (`pending`, `buffered`, `drain`, `drain_into`,
`write_pending`, `write_bytes`) first move the whole bytes still waiting;
`mark` and `rewind` save and restore the waiting bits with the length.

Moving the bytes with one store after every write, instead of waiting
for 32 bits, kept less than half of the gain natively (one run: text
level one 5.56 ms, binary level one 0.98 ms, against 4.98 and 0.76
below). Wasm GC, whose arrays trap out of range in any case, also takes
the eight-byte store: the checked byte path measured 11.62/1.69 ms at
text/binary level one, the new one 11.26/1.40 and 11.37/1.40 in the same
session. JS keeps its 32-bit accumulator and byte stores. Making the
eight-byte store inline in every caller, with the near-end path apart,
was not faster natively (5.11 ms at text level one) and was not kept.

The same codec_bench "zstd encode" command as above, alternating an
unchanged copy of the sources and the changed ones, pinned to one CPU.
Means in milliseconds over the runs on each side: three on native and
JS, two on Wasm and Wasm GC.

| Input, level | Native before → after | Wasm before → after | Wasm GC before → after | JS before → after |
|---|---:|---:|---:|---:|
| text, 1 | 5.96 → 4.98 | 17.57 → 16.42 | 11.78 → 11.32 | 88.26 → 88.20 |
| text, 3 | 6.51 → 5.49 | 18.55 → 17.63 | 11.29 → 10.87 | 114.80 → 114.48 |
| text, 5 | 12.54 → 11.56 | 28.35 → 27.36 | 19.22 → 19.06 | 144.00 → 141.51 |
| text, 8 | 27.67 → 26.46 | 48.71 → 47.17 | 49.49 → 49.58 | 203.19 → 203.02 |
| text, 12 | 68.02 → 66.88 | 91.01 → 89.80 | 115.18 → 112.65 | 309.11 → 316.52 |
| binary, 1 | 1.06 → 0.76 | 2.28 → 1.65 | 1.63 → 1.40 | 8.94 → 9.18 |
| binary, 3 | 2.76 → 2.50 | 5.67 → 5.10 | 4.65 → 4.52 | 47.53 → 50.23 |
| binary, 12 | 10.81 → 10.78 | 11.54 → 11.02 | 25.32 → 24.17 | 104.50 → 106.21 |

Native is 16% faster at text levels one and three and 28% at binary
level one, where entropy coding is the largest share; the gain shrinks
as matching takes over, to 2% at text level twelve. Native binary level
twelve alternates between about 10.2 and 11.9 ms on both sides (runs of
10.20, 10.39, 11.84 before and 9.96, 11.94, 10.43 after), so it shows no
change. Wasm is 1–27% faster and Wasm GC up to 14%, except text level
eight, unchanged. JS runs the same code as before: its higher means come
from single runs with large deviations (binary level three 55.45 ±
6.38 ms, text level twelve 332.60 ± 46.81 ms); the medians of the three
runs are within 2.5% of each other on every row, in either direction.

A native `perf record -e cycles:u -F 4000` of the two level-one cases
afterwards (11,349 samples): `Encoder::encode_block` 20.7%, the Huffman
literal streams with the writes inlined in them 18.3%, match length 8.4%,
`BitPacker::flush` 7.8%, the fast finder's hash and length 6.1% each,
`CTable::encode` 5.9%.

The brotli encoder writes through the same packer. codec_bench's
"encode" (`-i 1`), alternated the same way, two runs on each side; the
deflate rows, which do not use it, show the spread between runs:

| Input | Native before → after | Wasm before → after | Wasm GC before → after | JS before → after |
|---|---:|---:|---:|---:|
| brotli, text | 13.82 → 13.09 | 45.65 → 43.97 | 15.73 → 15.35 | 27.14 → 26.79 |
| brotli, binary | 4.53 → 4.44 | 11.93 → 11.35 | 5.27 → 5.15 | 7.93 → 8.27 |
| deflate, text | 13.16 → 13.10 | 28.87 → 28.54 | 20.92 → 21.19 | 38.45 → 38.77 |
| deflate, binary | 3.27 → 3.23 | 9.06 → 9.07 | 5.43 → 5.42 | 9.07 → 9.32 |

Brotli is 2–5% faster on native, Wasm and Wasm GC; on JS, which runs
the same code as before, it moves with the deflate rows.

Unchanged: the 276 published compression counts (all 300 frames decode
with gaato and `zstd -d`), the SHA-256 pins of both encoders on all four
targets, and both crosschecks (2,360 zstd streams through `zstd -d` and
Node, 3,071 brotli streams through the reference decoder).

### Where encoding speed stands

All four targets as measured above (the "after" columns), against the
starting point, and zstd 1.5.7's `zstd -b<level>` on the same two files,
measured again in the same session on the same CPU (text 299.0, 229.2,
112.0, 47.6 and 24.8 MB/s; binary 726.8, 186.4 and 36.6 MB/s). Unlike our
benchmark, `zstd -b` gives the encoder the input's size. The last column
is how many times as long as the reference native takes.

| Input, level | Native start → now | Wasm start → now | Wasm GC start → now | JS start → now | Native vs zstd, start → now |
|---|---:|---:|---:|---:|---:|
| text, 1 | 11.85 → 4.98 ms (105 MB/s) | 40.00 → 16.42 ms | 13.67 → 11.32 ms | 94.08 → 88.20 ms | 6.9 → 2.8 |
| text, 3 | 12.98 → 5.49 ms (96 MB/s) | 42.53 → 17.63 ms | 14.94 → 10.87 ms | 117.13 → 114.48 ms | 5.7 → 2.4 |
| text, 5 | 22.38 → 11.56 ms (45 MB/s) | 70.91 → 27.36 ms | 21.89 → 19.06 ms | 149.87 → 141.51 ms | 4.6 → 2.5 |
| text, 8 | 47.62 → 26.46 ms (20 MB/s) | 125.83 → 47.17 ms | 49.46 → 49.58 ms | 206.25 → 203.02 ms | 4.2 → 2.4 |
| text, 12 | 105.01 → 66.88 ms (7.8 MB/s) | 192.79 → 89.80 ms | 105.26 → 112.65 ms | 306.97 → 316.52 ms | 5.0 → 3.2 |
| binary, 1 | 1.55 → 0.76 ms (173 MB/s) | 4.12 → 1.65 ms | 1.82 → 1.40 ms | 9.80 → 9.18 ms | 8.6 → 4.2 |
| binary, 3 | 4.28 → 2.50 ms (52 MB/s) | 12.09 → 5.10 ms | 4.95 → 4.52 ms | 47.68 → 50.23 ms | 6.0 → 3.6 |
| binary, 12 | 21.90 → 10.78 ms (12 MB/s) | 23.51 → 11.02 ms | 20.41 → 24.17 ms | 104.12 → 106.21 ms | 6.1 → 3.0 |

Native runs 1.6 to 2.4 times as fast as at the start and Wasm 2.1 to
2.7 times; Wasm now takes 1.0 to 3.3 times as long as native. Native takes 2.4 to
4.2 times as long as zstd 1.5.7, most at the fastest binary level. Wasm
GC is 1.0 to 1.4 times as fast up to text level eight and at binary
levels one and three; at level twelve
it is slower than the starting table (text 7%, binary 18%), the rows the
earlier refreshed baselines found unstable and the shared history
slowed on binary input (above). JS, which keeps the checked byte paths
throughout, is within 7% of its starting times either way.
