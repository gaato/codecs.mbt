# P3: sequence encoding and fast matching

This is the implementation and measurement record for P3, measured on
2026-11-13 with MoonBit 0.10.20, Zstandard CLI 1.5.7 and Node 26.13.1.
It is not a claim that the later compression strategies are implemented.

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
encoder windows need at most 20 offset extra bits, so external window
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

Levels 1 and 2 use their size-class parameters. Levels 3..12 temporarily
use level-2 parameters in full, including its window and hash sizes.
The strategy column is ignored during P3, including small-input rows
where the reference uses dfast. P4/P5 still own those dedicated strategies.

Literals choose raw, RLE, a new Huffman tree, or a valid previous tree
(Treeless). A new tree replaces the previous one only when written into
an accepted block. Raw/RLE blocks preserve it; reset invalidates it.
Four Huffman streams now compute their jump-table sizes first and write
directly to the block output, removing the private stream buffer and copy.
Only the small Huffman weight scratch remains. The total conservative
encoder bound, including match and sequence storage, is 3,698,604 bytes;
the accounting and limit tests are in RESOURCE_BOUNDS.md.

## Compression sizes

The 23 corpus files were checked against every size and SHA-256 in
`bench/compare/corpora.tsv`. Both encoders include checksums and known
content size. The gaato rows use `compress`; reference rows use a named
file with `zstd -1/-2 --check -c -q`, allowing the reference to choose its
size class. All 50 gaato outputs (two levels, 23 corpus files plus two
bench inputs) decode back with gaato and `zstd -d`. Timing was disabled.

Reproduce from the repository root (substitute the corpus directories):

```sh
moon run scripts/compare_codecs.mbtx -- ratio --format zstd --time 0 --corpus /home/gaato/works/deflate-research/corpus/silesia --corpus /home/gaato/works/deflate-research/corpus/canterbury
```

Delta is `(gaato_bytes / reference_bytes - 1) * 100`; negative is smaller.
Aggregate sizes are close, but the per-file target remains open for
level-2 `kennedy.xls` (+11.16%) and `alice29.txt` (+4.95%). For alice,
the reference's <=256 KiB level-2 row uses dfast, still outside P3. This
does not explain kennedy, whose large-input row uses fast. Its eight
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

| Corpus / file | gaato 1 | zstd -1 | delta | gaato 2 | zstd -2 | delta |
|---|---:|---:|---:|---:|---:|---:|
| _build/compare/ratio/bench_text | 160661 | 158899 | +1.11% | 159654 | 157042 | +1.66% |
| _build/compare/ratio/bench_binary | 123123 | 118359 | +4.03% | 97509 | 108864 | -10.43% |
| silesia/mr | 3830928 | 3817777 | +0.34% | 3606420 | 3596433 | +0.28% |
| silesia/nci | 2802989 | 2853982 | -1.79% | 2851341 | 2890691 | -1.36% |
| silesia/sao | 6227511 | 6249095 | -0.35% | 5815411 | 5804517 | +0.19% |
| silesia/xml | 692486 | 694925 | -0.35% | 675078 | 677523 | -0.36% |
| silesia/osdb | 3782223 | 3728615 | +1.44% | 3513605 | 3491504 | +0.63% |
| silesia/samba | 5453907 | 5500201 | -0.84% | 5230019 | 5228477 | +0.03% |
| silesia/x-ray | 6771838 | 6772240 | -0.01% | 6672113 | 6680315 | -0.12% |
| silesia/dickens | 4282684 | 4262734 | +0.47% | 3900194 | 3867462 | +0.85% |
| silesia/mozilla | 20019732 | 19983517 | +0.18% | 19004498 | 18951213 | +0.28% |
| silesia/ooffice | 3565137 | 3593264 | -0.78% | 3316064 | 3311698 | +0.13% |
| silesia/reymont | 2164139 | 2150826 | +0.62% | 2089801 | 2068474 | +1.03% |
| silesia/webster | 13754373 | 13669761 | +0.62% | 12929203 | 12824630 | +0.82% |
| canterbury/sum | 13631 | 13624 | +0.05% | 13430 | 13473 | -0.32% |
| canterbury/ptt5 | 49322 | 51670 | -4.54% | 50492 | 52759 | -4.30% |
| canterbury/cp.html | 8840 | 8824 | +0.18% | 8645 | 8633 | +0.14% |
| canterbury/xargs.1 | 1863 | 1864 | -0.05% | 1859 | 1851 | +0.43% |
| canterbury/fields.c | 3558 | 3560 | -0.06% | 3603 | 3593 | +0.28% |
| canterbury/lcet10.txt | 159237 | 158524 | +0.45% | 150171 | 148564 | +1.08% |
| canterbury/alice29.txt | 60068 | 59661 | +0.68% | 60191 | 57352 | +4.95% |
| canterbury/grammar.lsp | 1340 | 1341 | -0.07% | 1342 | 1333 | +0.68% |
| canterbury/kennedy.xls | 116186 | 115395 | +0.69% | 124773 | 112242 | +11.16% |
| canterbury/asyoulik.txt | 54695 | 54516 | +0.33% | 52287 | 51858 | +0.83% |
| canterbury/plrabn12.txt | 219036 | 217845 | +0.55% | 200211 | 198467 | +0.88% |
| **silesia total** | 73347947 | 73276937 | +0.10% | 69603747 | 69392937 | +0.30% |
| **canterbury total** | 687776 | 686824 | +0.14% | 667004 | 650125 | +2.60% |
