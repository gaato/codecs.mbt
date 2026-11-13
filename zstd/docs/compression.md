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

`internal/match/Fast` uses one hash table and a sliding byte buffer of at
most window + one block. Hash positions rebase after each block, avoiding
counter overflow on long frames. The finder sees only complete blocks
from the existing cutter, never step boundaries. It retains history for
raw and RLE blocks too. Candidate eligibility checks both frame start and
window distance before reading. Hash widths and constants follow
`ZSTD_hash{4,5,6,7}`; four-byte matches remain eligible regardless of hash
width. targetLength supplies the minimum skip step, increasing after
literal runs. Recent-offset matches two bytes ahead, and immediate
repeat-2 matches, receive the reference fast encoder's priority. The loop
is scalar and also considers other recent offsets, rather than copying
the reference's pipelined pointer loop exactly.

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
and rebase both tables when discarding old bytes. Cross-boundary hashes
are completed only once the next block provides their lookahead.
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
The earlier fast-only measurement left level-two `alice29.txt` at +4.95%;
selecting its double-fast row reduces that to +0.02% (60,191 becomes
57,363 bytes; reference 57,352). Level-two `kennedy.xls` remains +11.16%,
on its unchanged large-input fast row. Its eight
blocks contain 95,208 literals versus the reference's 85,788: literals
take 74,723 versus 64,677 bytes and sequences 50,013 versus 47,528.
Most of that gap is match selection, not frame/table headers. Exact
reference search scheduling and entropy-aware match selection remain
unimplemented; their separate contributions have not been isolated.

The original greedy recent-distance selection made nci 9.61%/11.28%
larger. Inspecting its literal and sequence sections identified expensive
sequence choices despite fewer literals. Adding the reference's two
repeat priorities reduced nci to -1.79%/-1.36%. Silesia totals improved
from +0.76%/+1.31% to +0.10%/+0.30%. No corpus-specific tuning was added.

The per-file figures below include the two supplementary bench inputs.

| Corpus / file | gaato 1 | zstd -1 | delta | gaato 2 | zstd -2 | delta | gaato 3 | zstd -3 | delta | gaato 4 | zstd -4 | delta |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| _build/compare/ratio/bench_text | 160661 | 158899 | +1.11% | 159654 | 157042 | +1.66% | 148599 | 148537 | +0.04% | 148279 | 148212 | +0.05% |
| _build/compare/ratio/bench_binary | 123123 | 118359 | +4.03% | 97509 | 108864 | -10.43% | 98818 | 100216 | -1.39% | 93672 | 96133 | -2.56% |
| silesia/mr | 3830928 | 3817777 | +0.34% | 3606420 | 3596433 | +0.28% | 3548083 | 3548071 | +0.00% | 3487316 | 3489400 | -0.06% |
| silesia/nci | 2802989 | 2853982 | -1.79% | 2851341 | 2890691 | -1.36% | 2822975 | 2835400 | -0.44% | 2823574 | 2836688 | -0.46% |
| silesia/sao | 6227511 | 6249095 | -0.35% | 5815411 | 5804517 | +0.19% | 5550898 | 5531939 | +0.34% | 5423232 | 5401813 | +0.40% |
| silesia/xml | 692486 | 694925 | -0.35% | 675078 | 677523 | -0.36% | 636752 | 636016 | +0.12% | 635514 | 634478 | +0.16% |
| silesia/osdb | 3782223 | 3728615 | +1.44% | 3513605 | 3491504 | +0.63% | 3498425 | 3501634 | -0.09% | 3472969 | 3477593 | -0.13% |
| silesia/samba | 5453907 | 5500201 | -0.84% | 5230019 | 5228477 | +0.03% | 4950010 | 4957768 | -0.16% | 4907735 | 4919655 | -0.24% |
| silesia/x-ray | 6771838 | 6772240 | -0.01% | 6672113 | 6680315 | -0.12% | 6084823 | 6086002 | -0.02% | 5710203 | 5712031 | -0.03% |
| silesia/dickens | 4282684 | 4262734 | +0.47% | 3900194 | 3867462 | +0.85% | 3662262 | 3664984 | -0.07% | 3580094 | 3588622 | -0.24% |
| silesia/mozilla | 20019732 | 19983517 | +0.18% | 19004498 | 18951213 | +0.28% | 18453645 | 18281292 | +0.94% | 18246076 | 18103876 | +0.79% |
| silesia/ooffice | 3565137 | 3593264 | -0.78% | 3316064 | 3311698 | +0.13% | 3141137 | 3128288 | +0.41% | 3066258 | 3053902 | +0.40% |
| silesia/reymont | 2164139 | 2150826 | +0.62% | 2089801 | 2068474 | +1.03% | 1935883 | 1937977 | -0.11% | 1913933 | 1917276 | -0.17% |
| silesia/webster | 13754373 | 13669761 | +0.62% | 12929203 | 12824630 | +0.82% | 12085709 | 12107198 | -0.18% | 11892552 | 11925012 | -0.27% |
| canterbury/sum | 13631 | 13624 | +0.05% | 13430 | 13473 | -0.32% | 13368 | 13379 | -0.08% | 13068 | 13070 | -0.02% |
| canterbury/ptt5 | 49322 | 51670 | -4.54% | 50492 | 52759 | -4.30% | 54297 | 54424 | -0.23% | 54482 | 54596 | -0.21% |
| canterbury/cp.html | 8840 | 8824 | +0.18% | 8645 | 8633 | +0.14% | 8464 | 8468 | -0.05% | 8439 | 8438 | +0.01% |
| canterbury/xargs.1 | 1863 | 1864 | -0.05% | 1859 | 1851 | +0.43% | 1804 | 1803 | +0.06% | 1804 | 1767 | +2.09% |
| canterbury/fields.c | 3558 | 3560 | -0.06% | 3603 | 3593 | +0.28% | 3370 | 3384 | -0.41% | 3370 | 3212 | +4.92% |
| canterbury/lcet10.txt | 159237 | 158524 | +0.45% | 150171 | 148564 | +1.08% | 141027 | 141028 | -0.00% | 140526 | 140402 | +0.09% |
| canterbury/alice29.txt | 60068 | 59661 | +0.68% | 57363 | 57352 | +0.02% | 56984 | 56974 | +0.02% | 56984 | 54286 | +4.97% |
| canterbury/grammar.lsp | 1340 | 1341 | -0.07% | 1342 | 1333 | +0.68% | 1302 | 1295 | +0.54% | 1302 | 1258 | +3.50% |
| canterbury/kennedy.xls | 116186 | 115395 | +0.69% | 124773 | 112242 | +11.16% | 112060 | 111831 | +0.20% | 111064 | 110925 | +0.13% |
| canterbury/asyoulik.txt | 54695 | 54516 | +0.33% | 52287 | 51858 | +0.83% | 50336 | 50328 | +0.02% | 51156 | 51146 | +0.02% |
| canterbury/plrabn12.txt | 219036 | 217845 | +0.55% | 200211 | 198467 | +0.88% | 191716 | 191688 | +0.01% | 189649 | 189624 | +0.01% |
| **silesia total** | 73347947 | 73276937 | +0.10% | 69603747 | 69392937 | +0.30% | 66370602 | 66216569 | +0.23% | 65159456 | 65060346 | +0.15% |
| **canterbury total** | 687776 | 686824 | +0.14% | 664176 | 650125 | +2.16% | 634728 | 634602 | +0.02% | 631844 | 628724 | +0.50% |

### Remaining outliers

No Silesia or Canterbury file exceeds +3% at level three. At level four,
`fields.c` (+4.92%), `grammar.lsp` (+3.50%) and `alice29.txt` (+4.97%)
use the temporary level-three double-fast row because the requested row
is greedy. This is a known limitation until the later strategies land.
Forcing only `--zstd=strat=2` on the reference's level-four row gives
3,377 / 1,295 / 55,794 bytes respectively, versus its normal greedy
3,212 / 1,258 / 54,286. The remaining difference on alice also reflects
the different fallback hash parameters (the level-three reference is
56,974 versus our 56,984). These comparisons distinguish the strategy
gap from entropy overhead; no corpus-specific adjustment was made.

Recounting `kennedy.xls` confirms the earlier level-two gap: 98,842
sequences versus 99,302, with 9,420 more literals. The 12,531-byte size
difference consists of 10,046 literal-section bytes and 2,485 sequence
bytes, with identical frame/block overhead. At level three both encoders
have 84,664 literals and 96,680 sequences: our literal sections cost
64,201 versus 63,849 bytes, sequence sections 47,822 versus 47,945.
At level four the literal counts differ by one (84,236 versus 84,235),
and both have 96,754 sequences. This supports match selection as the
main fast-only loss, while also exposing a smaller entropy-cost gap.
The existing fast finder performs scalar searches and extra recent-offset
comparisons rather than the reference's pipelined search. Its precise
contribution is not isolated here; changing that completed layer is
outside this change, and its output remains unchanged.

The supplementary `bench_binary` level-one outlier (+4.03%) also stays
on the unchanged fast path: it emits zero sequences and 131,072 literals,
versus 379 sequences and 125,650 literals in the reference. Literal
sections cost 123,106 versus 117,547 bytes and sequence sections 1 versus
796. The same match-selection limitation is visible there. The two
supplementary bench inputs are not part of either corpus total.

## Existing parameter-adjustment limitation

The inherited `params_for` shrinks windowLog for known content sizes, but
leaves hashLog and chainLog at their size-class row values. In contrast,
Zstandard 1.5.7's `ZSTD_adjustCParams_internal` also caps hashLog at
`dictAndWindowLog + 1` and the chain's cycleLog at `dictAndWindowLog`.
For example, a 1,000-byte level-three input retains hashLog 15 and chainLog
14 here; the reference can reduce these to 11 and 10. The resulting larger
tables remain inside the bound and produce valid streams, but use more
memory and can affect small-input match selection. This pre-existing
parameter difference is reported without changing the completed parameter
layer. The declared-content-size mismatch behavior is likewise preserved.
