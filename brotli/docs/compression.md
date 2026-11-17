# Encoding qualities

Quality 4 is the lazy encoder with one Huffman code per category. Its
default output and memory bounds are unchanged, preserving this module's
original encoder and pinned streams. Qualities 0..3 and 5..11 port google/brotli 1.2.1's encoder under
MIT; `LICENSE-encoder` contains its notice. The release archive is pinned
by `scripts/reference/SOURCE.sha256`, cached under the reference script's
`target/`, and verified before extraction by `source.mbtx`.
`scripts/reference/cli.mbtx` builds and version-checks the CLI from that
source for both vector generators and byte-identity crosschecks, so their
results do not depend on the installed Brotli version. Decoder interoperability
uses the independently installed PATH `brotli` and Node.

## Reference parameters and output

Qualities 0 and 1 port `compress_fragment.c` and
`compress_fragment_two_pass.c`: one pass with cached command codes, or two
passes with a 128 KiB literal/command program. The pinned source's stored
command-code arena is 512 bytes (448 initial bits).
The fast Huffman builder preserves its count-only Shell-sort ties.
Qualities 2 and 3 select H2 and H3 at every supported window and size hint,
with reference greedy parsing and 16 KiB input blocks; H4/H54 are the
reference's quality 4, which this module deliberately does not select.
Quality 2 uses shallow static-dictionary search and fixed command/distance
codes for small command sets; quality 3 uses ordinary dynamic trees.

The q0/q1 encoders reproduce the CLI's 512 KiB read schedule in both modes.
This schedule matches the pinned CLI in 360 C API probes over windows 10,
16, 18, 22 and 24, read edges and two output sizes. A full
512 KiB batch uses `PROCESS`, even when `Finish` is already known; an exact
multiple ends with an empty `FINISH`. The requested window can split each
batch further. The declared fast-path window is at least 18 bits.
Qualities 0..3 ignore the hint. Caller splits therefore do not change output.

Raw dictionaries do not raise the quality in the pinned 1.2.1 implementation.
Its q0/q1 fragment paths ignore them; H2/H3 have no compound-dictionary
search. Quality 2 still shifts static-word distances past the raw dictionary,
so decoding requires that dictionary. Quality 3 ignores it. Flushes terminate
the current fragment or meta-block and emit byte-aligned metadata. Dictionary
and flush streams at qualities 0..3 undergo CLI decoder interoperability.
The native low-quality pins cover 120 CLI digests in both hint modes, including
fragment/block/read edges, small windows, ring wraps, input-buffer slides,
random and multilingual
input. Tests also check wrong hints, random splits, reset and allocation
bounds after each step. JS, Wasm and Wasm GC run 64 small CLI digests and
the branch, streaming, flush, dictionary and reset checks on inputs up to
35 KiB. The larger identity matrix, distant matches and fragment-size bound
matrix run only on native, keeping portable-target CI time bounded.

Qualities 5..9 use H40/H41/H42 for windows up to 16 bits, and H5/H6 or the tagged
H58/H68 hashers for larger windows, selected by quality and size hint.
The tagged search is evaluated with scalar comparisons in the reference's
visit order. The selector matches the Linux reference: tagged hashers at
qualities 5 and 6, ordinary H5/H6 at 7..9. A hint of at least 1 MiB selects
the five-byte hash family when the window is at least 19 bits.

The static dictionary search, distance-cache scores, lazy parse, sparse
search, command extension, UTF8 contexts, greedy histogram merging,
block switches, Huffman ties and code-length runs follow the reference.
Input blocks are 64 KiB at qualities 5..8, up to 256 KiB at 9..11. Several input
blocks can share a meta-block, up to `min(2 * max(window, input block), 16 MiB)`.
Reference dictionary hash tables are initialized only by the qualities that
search them; quality 4 does not allocate them. The logarithm lookup uses compiled
constants, preserving the reference's float-to-double rounding.

Qualities 10 and 11 use Brotli's H10 tree directly. It has one 17-bit hash,
two children per window position, a 64-level search and a 128-byte tree
comparison limit. A short tail can be searched without inserting it;
stitching and sparse range insertion follow the reference's order.
`parts/lz77/bt_matchfinder.mbt` implements libdeflate's two-hash tree and
different insertion and match ordering, so it cannot supply the H10 byte
contract.

The shortest-path parser uses packed 16-byte nodes, the reference's
Float32 cost arithmetic and its ordered start-position queue. Quality 10
finds matches while updating the path. Quality 11 archives the H10 matches
and runs two cost passes, deriving the second model from the first pass's
commands. Both use full static-dictionary transform lookup, entropy-code
block partitioning, context histogram clustering, distance-parameter
selection and Huffman count optimization. All ties follow the reference.

`compress` uses the known input length, as the CLI does for a named file.
`Encoder(size_hint=n)` produces the same output at the same quality and
window. Without a hint, the encoder follows the CLI's 512 KiB stdin read
schedule. A wrong hint can change parameter choices without invalidating the
stream. Hints are clamped to 0..1 GiB, with zero selecting inferred stdin
semantics. Quality 4 ignores hints and keeps its one-shot window reduction.
At qualities 10 and 11, neither the hasher nor these parameter choices
depends on the hint; both modes still undergo the reference crosscheck.

The pinned CLI vectors cover both hint modes, small windows, both hash
families, multilingual contexts, mixed input, 512 KiB edges and long streams
through meta-block boundaries and input-buffer slides. The crosscheck
compares whole streams byte for byte and decodes them with the CLI and
Node. Dictionary and flush streams require decoder agreement and do not
promise reference encoder identity. Qualities 4..11 use the module's raw
dictionary index; the low-quality limitations are described above.
The shared conformance harness is run from a disposable consumer by
`scripts/conformance.mbtx`, keeping it outside published dependencies.

The HQ pins cover 104 CLI digests across both qualities and hint modes,
including small tails, windows 10 through 24, random and multilingual data,
512 KiB boundaries, changing alphabets and multi-block streams. Separate tests exercise raw
dictionaries, flushes, random splits, reset, H10 position wraps and exact
tree storage at a 24-bit window. The bounds account for the full tree even
with a wrong size hint; only an actual final first input block permits the
reference's smaller forest allocation.

## Ratio and time

### All qualities, P8c

Measured on 2026-11-18 from the P8c working sources, Intel Core i5-10400F,
Linux x86_64, MoonBit 0.10.20+65efd5b93 and the pinned brotli 1.2.1 CLI.
Both inputs have 1,200,000 bytes and request window 22. `text` repeats a
sentence; `mixed` replaces 30% of each 10,000-byte region with seeded random
bytes. Percentages are output/input. Times are means of 15 native process
runs after warmup, including startup and named-file I/O on both sides,
under the shared lock and pinned to CPU 2. `scripts/quality_compare.mbtx`
asserts byte identity for 0..3 and 5..11.

| Input | Quality | MoonBit bytes (%) | CLI bytes (%) | MoonBit ms | CLI ms |
|---|---:|---:|---:|---:|---:|
| text | 0 | 673 (0.056%) | 673 (0.056%) | 4.40 | 1.80 |
| text | 1 | 599 (0.050%) | 599 (0.050%) | 4.80 | 1.33 |
| text | 2 | 110 (0.009%) | 110 (0.009%) | 5.40 | 2.40 |
| text | 3 | 90 (0.008%) | 90 (0.008%) | 5.33 | 3.00 |
| text | 4 | 296 (0.025%) | 86 (0.007%) | 6.47 | 3.80 |
| text | 5 | 134 (0.011%) | 134 (0.011%) | 5.73 | 3.00 |
| text | 6 | 134 (0.011%) | 134 (0.011%) | 6.67 | 2.93 |
| text | 7 | 134 (0.011%) | 134 (0.011%) | 8.00 | 2.60 |
| text | 8 | 134 (0.011%) | 134 (0.011%) | 10.53 | 2.53 |
| text | 9 | 134 (0.011%) | 134 (0.011%) | 16.13 | 2.47 |
| text | 10 | 79 (0.007%) | 79 (0.007%) | 33.80 | 14.87 |
| text | 11 | 79 (0.007%) | 79 (0.007%) | 38.20 | 17.80 |
| mixed | 0 | 397453 (33.121%) | 397453 (33.121%) | 15.93 | 9.87 |
| mixed | 1 | 363449 (30.287%) | 363449 (30.287%) | 15.27 | 9.27 |
| mixed | 2 | 362930 (30.244%) | 362930 (30.244%) | 22.07 | 11.80 |
| mixed | 3 | 362264 (30.189%) | 362264 (30.189%) | 23.73 | 12.20 |
| mixed | 4 | 361212 (30.101%) | 361298 (30.108%) | 20.80 | 16.40 |
| mixed | 5 | 362446 (30.204%) | 362446 (30.204%) | 31.00 | 13.80 |
| mixed | 6 | 362446 (30.204%) | 362446 (30.204%) | 39.47 | 15.27 |
| mixed | 7 | 362446 (30.204%) | 362446 (30.204%) | 48.27 | 16.73 |
| mixed | 8 | 362446 (30.204%) | 362446 (30.204%) | 67.67 | 21.07 |
| mixed | 9 | 361899 (30.158%) | 361899 (30.158%) | 122.33 | 35.20 |
| mixed | 10 | 361068 (30.089%) | 361068 (30.089%) | 474.80 | 294.27 |
| mixed | 11 | 360938 (30.078%) | 360938 (30.078%) | 1310.87 | 869.73 |

The general ratio adapter also accepts `--qualities 0,1,...,11` (the
default is all qualities):

```sh
flock "$GATES_LOCK" taskset -c 2 moon run scripts/compare_codecs.mbtx -- ratio --format brotli --qualities 0,1,2,3,4,5,6,7,8,9,10,11
```

It measures the selected gaato qualities, compares sizes with the same
pinned CLI and checks dumped streams using the independently installed
decoder. Other MoonBit encoders retain their own supported levels.

### P8c quality-4 speed

Measured on 2026-11-18 against the P8b baseline captured before this stage,
with the same CPU, toolchain and benchmark fixtures described below,
Node 26.13.1 and moonrun 0.1.20261104 (940aa18).
All runs use the release profile, hold the shared lock and use CPU 2.
Four alternating before/after pairs warm both inputs for at least one
second and discard five text samples. Wasm uses 40 measured samples per
process; the other targets use 100. Values compare means; negative is
faster. Every result is within the 1% regression limit. Quality-4 SHA-256
pins stay unchanged.

| Target | Text change | Binary change |
|---|---:|---:|
| Native | -0.55% | 0.35% |
| JS | -0.34% | 0.26% |
| Wasm | -7.35% | -2.70% |
| Wasm GC | -0.37% | -0.96% |

### Brotli test cost

Measured on 2026-11-18 with `moon test --target TARGET brotli/src` in
the default test profile, excluding compilation (both versions were
prebuilt), with the versions above. Each before/after batch runs the four
targets concurrently on separate physical cores 2, 3, 4 and 5 under the
shared lock. The same target uses the same core in both batches. These
are single-run local wall times, not CI timings; elapsed differences also
include scheduling and clock variation. The baseline is the committed P8b
source saved before P8c. The last column measures only the two new low-quality
test files, separately on CPU 2 with prebuilt binaries, including launcher
and process startup; it gives a conservative view of their additional cost.

| Target | Before P8c (s) | After P8c (s) | Change (s) | q0..3 files (s) |
|---|---:|---:|---:|---:|
| Native | 269.8 | 298.8 | 29.0 | 2.8 |
| JS | 328.9 | 338.2 | 9.3 | 1.2 |
| Wasm | 440.8 | 442.2 | 1.4 | 1.1 |
| Wasm GC | 119.8 | 121.8 | 2.0 | 0.7 |

The large q0..3 identity and fragment matrices are native-only. Other
targets retain small branch-covering pins and streaming checks, with inputs
up to 35 KiB, to keep the stage's portable test cost small.

### Historical P8a and P8b measurements


The quality 4..9 table was measured at `6090cb02` on 2026-11-17 on an
Intel Core i5-10400F, Linux x86_64, MoonBit
0.10.20+65efd5b93 and brotli CLI 1.2.1. Both inputs contain 1,200,000 bytes.
`text` repeats a sentence; `mixed` replaces 30% of each 10,000-byte region
with seeded random bytes. Both request window 22. Percentages are output
bytes divided by input bytes. Times are means of 15 native process runs
after warmup, including startup and named-file I/O on both sides, under the
shared lock and pinned to CPU 2. They are end-to-end times, not inner-loop
throughput. The script asserts byte identity for qualities 5..11.

| Input | Quality | MoonBit bytes (%) | CLI bytes (%) | MoonBit ms | CLI ms |
|---|---:|---:|---:|---:|---:|
| text | 4 | 296 (0.025%) | 86 (0.007%) | 6.33 | 4.20 |
| text | 5 | 134 (0.011%) | 134 (0.011%) | 5.60 | 2.60 |
| text | 6 | 134 (0.011%) | 134 (0.011%) | 6.00 | 2.80 |
| text | 7 | 134 (0.011%) | 134 (0.011%) | 6.27 | 2.93 |
| text | 8 | 134 (0.011%) | 134 (0.011%) | 7.27 | 3.33 |
| text | 9 | 134 (0.011%) | 134 (0.011%) | 9.60 | 3.93 |
| mixed | 4 | 361212 (30.101%) | 361298 (30.108%) | 20.60 | 15.67 |
| mixed | 5 | 362446 (30.204%) | 362446 (30.204%) | 30.93 | 13.80 |
| mixed | 6 | 362446 (30.204%) | 362446 (30.204%) | 38.40 | 14.67 |
| mixed | 7 | 362446 (30.204%) | 362446 (30.204%) | 46.07 | 15.13 |
| mixed | 8 | 362446 (30.204%) | 362446 (30.204%) | 63.47 | 17.20 |
| mixed | 9 | 361899 (30.158%) | 361899 (30.158%) | 112.93 | 26.47 |

Qualities 10 and 11 were measured on 2026-11-18 with the same inputs,
window, versions and 15-run native process method:

| Input | Quality | MoonBit bytes (%) | CLI bytes (%) | MoonBit ms | CLI ms |
|---|---:|---:|---:|---:|---:|
| text | 10 | 79 (0.007%) | 79 (0.007%) | 31.80 | 15.53 |
| text | 11 | 79 (0.007%) | 79 (0.007%) | 36.20 | 17.73 |
| mixed | 10 | 361068 (30.089%) | 361068 (30.089%) | 446.53 | 290.27 |
| mixed | 11 | 360938 (30.078%) | 360938 (30.078%) | 1234.33 | 841.33 |

Quality is a tuning preset, so a higher value does not guarantee a smaller
stream on every input. The CLI itself shows that on these inputs.

An A/B on 2026-11-18 compares the P8b encoder with `6090cb02`, using
the same toolchain and CPU above. The fixtures from
`bench/src/compare_speed/data_test.mbt` contain 512 KiB of text and 128 KiB
of binary data. Runs hold the shared lock and use CPU 2. Four alternating
before/after pairs average each process's sample mean. Each quality warms
both fixtures for at least one second and has a discarded five-sample text benchmark.
Measured runs use 20 samples, except quality 4 on GC/JS and qualities 5 and
8 on GC, which use 100; those GC 5/8 runs warm for three seconds.
Negative percentages mean faster; the largest increase is 0.36%.

| Target | Quality 4 text | Quality 4 binary | Largest quality 5..9 change |
|---|---:|---:|---:|
| Native | +0.06% | -1.05% | -4.97% |
| Wasm | -12.72% | -3.53% | -4.70% |
| Wasm GC | -0.79% | +0.36% | -0.20% |
| JS | -3.76% | -1.45% | -13.78% |

Native and Wasm reject regular-hasher candidates with the reference's
unaligned four-byte comparison. GC and JS retain ordered byte comparisons
and use UInt32 for bounded distances and ring sums, avoiding JS BigInt:
the ring mask is below 2^25 and match lengths are at most 256 KiB.
Quality 4 uses its standard writer on native. The Wasm writer uses
unchecked command-table accesses, pairs literal codes and skips zero-width
extras, as GC/JS already do. Native and Wasm also reject a different
four-byte cached-match prefix before the wider match-length load. These
choices preserve the pinned stream and its memory bounds.

Reproduce from the repository root, with `GATES_LOCK` set to the host's
shared gate lock to keep concurrent work from skewing the timings:

```sh
flock "$GATES_LOCK" taskset -c 2 moon run brotli/scripts/quality_compare.mbtx
flock "$GATES_LOCK" moon run brotli/scripts/crosscheck.mbtx
```

The broader default-encoder ratio comparison remains in
[`bench/README.md`](https://github.com/gaato/codecs.mbt/blob/main/bench/README.md). The
[`RESOURCE_BOUNDS.md`](https://github.com/gaato/codecs.mbt/blob/main/brotli/RESOURCE_BOUNDS.md) table gives every quality's
bound, including size-hint-dependent hash tables.
