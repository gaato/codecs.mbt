# Encoding qualities

Quality 4 is the lazy encoder with one Huffman code per category. Its
default output and memory bounds are unchanged. Values 0..3 select 4.
Qualities 5..11 port google/brotli 1.2.1's encoder under
MIT; `LICENSE-encoder` contains its notice. The release archive is pinned
by `scripts/reference/SOURCE.sha256`, cached under the reference script's
`target/`, and verified before extraction by `source.mbtx`.
`scripts/reference/cli.mbtx` builds and version-checks the CLI from that
source for both vector generators and byte-identity crosschecks, so their
results do not depend on the installed Brotli version. Decoder interoperability
uses the independently installed PATH `brotli` and Node.

## Reference parameters and output

The port uses H40/H41/H42 for windows up to 16 bits, and H5/H6 or the tagged
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
Reference dictionary hash tables are initialized with the reference hasher;
quality 4 does not allocate them. The logarithm lookup uses compiled
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
Node. Dictionary and flush streams require decoder agreement; they use the
module's dictionary index and do not promise reference encoder identity.
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

An A/B on 2026-11-18 compares the current encoder with `6090cb02`, using
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
Quality 4 uses its standard writer on native, omits redundant command-table
range checks on Wasm, and pairs literal codes and skips zero-bit extras on
GC/JS. These choices preserve the pinned stream and its memory bounds.

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
