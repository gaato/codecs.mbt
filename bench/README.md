# gaato/codec_bench

Unpublished. Benchmarks of the workspace's codecs:

```sh
MOON_CC=cc taskset -c 2 moon bench --release --target native -p gaato/codec_bench
```

The inputs (`src/data_test.mbt`) are a deterministic text and a deterministic
binary stream, compressed by the reference implementations (`zstd -3`,
`brotli -q 9` and `gzip -6`), so that the decoders meet what common encoders
produce; the encoders compress what the decoders give back. The DEFLATE
benchmarks decode the raw DEFLATE data inside the gzip members.
`moon run scripts/gen_bench_data.mbtx` regenerates them; it needs the `zstd`,
`brotli` and `gzip` commands.

Pin the run to one CPU and compare runs taken alternately: differences of a
few percent between single runs are noise.

The PNG benchmarks decode a 512 x 384 8-bit RGB image, once as it is and
once interlaced (`src/png_data/`), filtered row by row as libpng chooses by
default and compressed by zlib; each runs through `gaato/png` and through
typst's `decode_png` for comparison. `moon run scripts/gen_png_vectors.mbtx`
regenerates them; it needs pypng.

`src/png_memory` is an executable that decodes those images ten times, so
that the peak memory of a target's build can be measured on its own, without
the compilation that `moon run` also counts:

```sh
moon build --release --target wasm
/usr/bin/time -f '%M KB' moonrun _build/wasm/release/build/gaato/codec_bench/png_memory/png_memory.wasm
```

On an Intel Core i5-10400F, pinned to one CPU, with MoonBit 0.10.16 (moon
0.1.20261016; moonrun for Wasm, Node 26.12.1 for JS, GCC 16.2 for Native), the
mean time to decode each image with gaato/png 0.1.0 and with typst 0.1.7, and
the peak memory of `png_memory`:

| Target | gaato/png | interlaced | typst | interlaced | `png_memory` peak |
|---|---:|---:|---:|---:|---:|
| Native | 2.31 ms | 3.21 ms | 1.52 ms | 2.31 ms | 4.6 MiB |
| Wasm | 3.85 ms | 5.43 ms | 3.10 ms | 5.46 ms | 26.0 MiB |
| Wasm GC | 3.46 ms | 4.40 ms | 3.48 ms | 4.37 ms | 30.3 MiB |
| JS | 5.70 ms | 6.39 ms | 36.1 ms | 43.2 ms | 67.7 MiB |

The peak is the process's, most of it the runtime and the compiled code: the
decoder itself holds 47,360 + 2 × (1 + 1,536) bytes for these images.

`src/png_corpus` decodes broken PNG files with gaato/png and with typst; see
[png/docs/robustness.md](../png/docs/robustness.md).

## Other MoonBit PNG decoders

`src/compare_png` holds the other PNG decoders on mooncakes.io behind one
shape: moonbitlang/typst 0.1.9 (`codecs`, its `decode_png`), gmlewis/image 0.17.18
(`png`) and mizchi/image 0.4.3 (`decode_png`). Each decodes a whole file, and
its output is brought to straight RGBA, 16 bits a sample, samples of fewer
bits widened by repeating their bits, so that it can be compared byte for byte
with gaato/png's: the samples of `decode`'s rows (which the conformance suite
checks against pypng's) with the palette and tRNS applied.

bikallem/image 0.1.0 (`png`) does not build here: moon 0.1.20261016 stops at
its dependency bikallem/compress 0.3.2, whose `moon.mod.json` "is no longer
supported", as is bikallem/image's own. It is not in `moon.mod`; its numbers
below come from copies of bikallem/image, bikallem/compress 0.3.2 and
bikallem/blit 0.2.2 whose manifests `moon fmt` migrated (formatting their code
too), in a workspace of their own with this repository's modules, through the
same code as `src/compare_png`.

Measured on 2026-10-23, on an Intel Core i5-10400F, with MoonBit 0.10.16 (moon
0.1.20261016; moonrun 0.1.20261016 for Wasm, Node 26.12.1 for JS, GCC 16.2.1
for Native). The benchmarks build typst 0.1.9, whose `codecs` sources are
those of 0.1.7, which the table above measured.

### Summary

| Package | Streaming | Memory for 8192 × 8192 RGBA, limit | Formats | CRC, Adler-32 | Targets | Time, ours = 1 (Native / Wasm / Wasm GC / JS) |
|---|---|---|---|---|---|---|
| [gaato/png](https://mooncakes.io/docs/gaato/png) 0.1.0 | Yes | `Decoder` 6.5 MiB; `decode` 262.6 MiB, 512 MiB by default | All, Adam7, APNG frames | All chunks (a bad ancillary one is skipped), yes | All four | 1 |
| [moonbitlang/typst](https://mooncakes.io/docs/moonbitlang/typst) 0.1.9 | No | 262.5 MiB, none | All, Adam7, APNG's default image | Not IEND's, no | All four | 0.66 / 0.82 / 1.0 / 6.4 |
| [gmlewis/image](https://mooncakes.io/docs/gmlewis/image) 0.17.18 | Input only | 264.2 MiB, 2^28 pixels | All, Adam7, APNG's default image | All chunks, yes | All four¹ | 8.8 / – / 6.8 / – |
| [bikallem/image](https://mooncakes.io/docs/bikallem/image) 0.1.0 | No | 526.1 MiB, 2^28 pixels | All, Adam7, APNG's default image | All chunks, yes | None as published² | 1.5 / 2.2 / 1.9 / 6.2 |
| [mizchi/image](https://mooncakes.io/docs/mizchi/image) 0.4.3 | Rows, once all inflated | Refused: 256 MiB inflated | 8-bit, no Adam7, APNG's default image | All chunks, yes | All four | 2.1 / 2.3 / 2.8 / 9.4 |

¹ On JS and Wasm the stack runs out on a 512 × 384 image. ² MoonBit 0.10.16's moon no longer reads its `moon.mod.json`, nor its dependency's; with them migrated, all four.

The times are for a 512 × 384 RGB image: each package's time over ours, below 1 when it is faster. Ours hands out rows in PNG's layout, the others an RGB or RGBA image; converting our rows to RGBA takes 1.6 (Native) to 2.0 (JS) times as long as the rows alone. The broken files below ran under a 2 GiB limit on the address space.

- **gaato/png**: input in pieces of any size, whole rows into your slices. `Decoder` holds two rows and a zlib decoder, with limits on a row's and a reported chunk's bytes; `decode` holds the whole image and checks its size from IHDR against `max_output` before allocating it. Every fixed-length chunk; text, iCCP, eXIf and any other on request. Every chunk's CRC: a bad one refuses the file in IHDR, PLTE, IDAT, IEND and an APNG's fcTL and fdAT, and leaves out an ancillary chunk; the Adler-32. PngSuite: 162 of 162 images as pypng reads them, 14 of 14 broken ones refused; APNG frames against the png crate; proofs. On 30,590 broken files neither `Decoder` nor `decode` crashes or hangs; `decode` refuses 356 at the header, whose IHDR claims more than 512 MiB.
- **moonbitlang/typst** (`codecs`): the whole file in, the whole image out. `decode_png` sets no limit: a 1 MB file of a 16384 × 16384 image needed more than 4 GiB of address space. tRNS, pHYs, iCCP and eXIf. The CRC of IHDR, PLTE and IDAT. PngSuite: 162 of 162, 14 of 14; the default image of 45 of 45 APNG vectors; neither crashes nor hangs on 30,590 broken files.
- **gmlewis/image** (`png`): input from a reader, the whole image out, with no limit but 2^28 pixels, where its sizes would overflow. No ancillary chunk; tRNS applied. Every chunk's CRC, ancillary ones too. PngSuite: 162 of 162, 14 of 14; 45 of 45 APNG vectors. Of 30,590 broken files, hangs on 893, most of them cut short, crashes on 8, and gives for 192 an image whose `at` aborts.
- **bikallem/image** (`png`): the whole file in, the whole image and its inflated data held, with no limit but 2^28 pixels. No ancillary chunk; tRNS applied. Every chunk's CRC, ancillary ones too. PngSuite: 162 of 162, 14 of 14; 45 of 45 APNG vectors. Crashes on 38 of 30,590 broken files, 34 of them damaged copies of a 1.5 KB image for which its buffer of inflated data grew past 3 GiB.
- **mizchi/image**: rows to a callback, once the whole image data is inflated; the inflated data and the RGBA image held, 777 MiB for 8191 × 8191. At most 256 MiB inflated, so 8192 × 8192 RGBA is refused; it allocates the image before inflating, 1.3 GiB for a 79-byte file. 8-bit only, tRNS only for indexed color. No ancillary chunk. Every chunk's CRC, ancillary ones too; IEND not required. PngSuite: 53 of 162 (108 refused, 1 other image), 14 of 14; 41 of 45 APNG vectors. Crashes on 173 of 30,590 broken files.

### Speed

`moon bench --release` of `src/compare_png`, pinned to one CPU, three rounds
taken alternately with the other packages and targets: the mean time to decode
the PNG benchmarks' image, plain / interlaced. Each package decodes to its own
output: gaato/png to rows in PNG's layout (3 bytes a pixel here, an
interlaced image's pass by pass, which `scatter` would put in place), and with
each row converted by `Converter::rgba8`; typst to the png crate's EXPAND
(RGB, 3 bytes a pixel); gmlewis/image and bikallem/image to Go's image types
(`RGBA`, 4 bytes); mizchi/image to RGBA (4 bytes).

| Package | Native | Wasm | Wasm GC | JS |
|---|---:|---:|---:|---:|
| gaato/png 0.1.0 | 2.36 / 3.23 ms | 3.82 / 5.69 ms | 3.35 / 4.48 ms | 5.65 / 6.54 ms |
| gaato/png 0.1.0, rows to RGBA | 3.81 / 4.69 ms | 6.79 / 9.32 ms | 5.91 / 7.48 ms | 11.3 / 11.3 ms |
| moonbitlang/typst 0.1.9 | 1.55 / 2.30 ms | 3.12 / 5.39 ms | 3.40 / 4.42 ms | 36.1 / 41.2 ms |
| gmlewis/image 0.17.18 | 20.7 / 27.9 ms | stack overflow | 22.9 / 25.5 ms | stack overflow |
| bikallem/image 0.1.0 | 3.55 / 7.26 ms | 8.44 / 17.3 ms | 6.52 / 11.4 ms | 34.8 / 40.2 ms |
| mizchi/image 0.4.3 | 5.00 ms / refused | 8.74 ms / refused | 9.30 ms / refused | 53.3 ms / refused |

gmlewis/image's inflater (gmlewis/flate 0.36.17) recurses for every match,
`read_literal` and `copy_history` calling each other until its 32 KiB window
fills: on JS ("RangeError: Maximum call stack size exceeded") and Wasm the
stack runs out on this image, while PngSuite's small images decode on all four
targets. Its benchmark is in `gmlewis_bench_test.mbt`, built for Native and
Wasm GC only. mizchi/image refuses interlaced images.

### Memory

`src/compare_png/memory` decodes one file with one decoder: gaato/png's
`Decoder` reading the file in 64 KiB pieces into a 64 KiB slice of rows, or
gaato/png's `decode` and the other packages' calls given the whole file. The
peak resident memory of the process (`/usr/bin/time -f %M`), the mean of three
runs, for RGBA images of a repeating pattern (0.5 MB and 2.0 MB as files),
next to a run that does nothing (`none`):

| Decoder | 4096 × 4096 (64 MiB of pixels) | 8192 × 8192 (256 MiB) |
|---|---:|---:|
| `none` | 5.3 MiB | 4.0 MiB |
| gaato/png `Decoder` | 9.3 MiB | 6.5 MiB |
| gaato/png `decode` | 71.2 MiB | 262.6 MiB |
| moonbitlang/typst | 71.5 MiB | 262.5 MiB |
| gmlewis/image | 73.2 MiB | 264.2 MiB |
| bikallem/image | 189.9 MiB | 526.1 MiB |
| mizchi/image | 247.4 MiB | refused, at 522.1 MiB |

mizchi/image inflates the image data whole and refuses more than 256 MiB of it
(mizchi/zlib 0.4.8's `default_max_decompressed_size`, which `decode_png` does
not let a caller change): 8192 × 8192 RGBA inflates to 268,443,648 bytes. An
8191 × 8191 image, 268,378,115 bytes inflated, decodes, at a peak of 777 MiB.

Files that claim more than they hold, or that hold a large image in a small
file, with the peak memory of each run (a 2.5 GiB limit on the address space,
`ulimit -v`, unless said):

| File | gaato/png `Decoder` | gaato/png `decode` | typst | gmlewis/image | bikallem/image | mizchi/image |
|---|---|---|---|---|---|---|
| 79 bytes: IHDR of 100000 × 100000 RGBA, then a few bytes of a cut zlib stream | `Corrupt`, 4.4 MiB | `LimitExceeded(Output)` at the header, 3.6 MiB | refused, 3.5 MiB | refused ("dimension overflow"), 3.3 MiB | refused, 5.1 MiB | refused after allocating, 1,286 MiB |
| 79 bytes: IHDR of 3,000,000 × 1 RGBA | `LimitExceeded(Memory)` at the header, 7.3 MiB | the same, 3.5 MiB | refused, 3.5 MiB | refused, 37.9 MiB | refused, 5.1 MiB | refused, 14.8 MiB |
| 74 bytes, from image-png's fuzzing corpus: IHDR of 32 × 8,388,640 16-bit RGB | `Truncated`, 3.7 MiB | `LimitExceeded(Output)` at the header (1.5 GiB of rows), 3.5 MiB | refused, 3.5 MiB | refused ("dimension overflow"), 3.4 MiB | refused, 3.1 MiB | refused, 3.4 MiB |
| 1.0 MB: a valid 16384 × 16384 RGBA image of zeros (1 GiB of pixels) | decoded, 6.8 MiB | `LimitExceeded(Output)` at the header, 4.5 MiB; decoded with `max_output` of 1 GiB, 1,029 MiB | crashes past the limit, at 454 MiB (and past a 4 GiB limit, at 789 MiB) | refused ("dimension overflow"), 6.3 MiB | refused ("dimension overflow"), 4.2 MiB | refused after allocating, 1,287 MiB |

gmlewis/image and bikallem/image refuse an image of 2^28 pixels or more, whose
8 bytes a pixel would overflow a 32-bit size; they set no other limit. typst's
`decode_png` passes `PngLimits::Unlimited`; its `decode_png_frame` passes the
png crate's 64 MiB default, which bounds the decoder's other buffers but not
the image. mizchi/image allocates the RGBA image, width × height × 4 bytes in
32-bit arithmetic, before it inflates anything. gaato/png's `decode` refuses
at the header an image of more than `max_output` bytes of rows, 512 MiB by
default, the image crate's `Limits::max_alloc`; its `Decoder` holds two rows
of at most `max_row_bytes`.

### Correctness

`src/compare_png/corpus` runs one decoder over files and prints what it makes
of each, on stderr, which is not buffered: a decoder that crashes takes the
process with it, so a driver starts it again after the last line. PngSuite's
valid images and the APNG vectors' default images are compared with
gaato/png's:

| Package | PngSuite's 162 valid images | Its 14 broken ones refused | APNG vectors' default image (45) |
|---|---:|---:|---:|
| gaato/png 0.1.0 | 162 (against pypng, in the conformance suite) | 14 | 45 (every frame, against the png crate) |
| moonbitlang/typst 0.1.9 | 162 | 14 | 45 |
| gmlewis/image 0.17.18 | 162 | 14 | 45 |
| bikallem/image 0.1.0 | 162 | 14 | 45 |
| mizchi/image 0.4.3 | 53 | 14 | 41 |

mizchi/image refuses PngSuite's 16-bit images (`unsupported color type/bit
depth`), its images of fewer than 8 bits (`decompressed size mismatch`) and its
interlaced ones, 108 in all, and gives another image for `tbrn2c08`: it
applies tRNS to indexed images only. bikallem/image gives an indexed image's
palette with tRNS as Go's premultiplied `RGBA` colors holding straight values;
read as straight, as here, they match, while code that takes them for
premultiplied ones, as Go's `RGBA` means, gets other colors.

Small files of a 32 × 32 RGB image (16 × 16 indexed for PLTE), each broken in
one way:

| File | gaato/png | typst | gmlewis/image | bikallem/image | mizchi/image |
|---|---|---|---|---|---|
| Adler-32 broken | refused | decoded | refused | refused | refused |
| CRC of IHDR, of PLTE, of IDAT broken | refused | refused | refused | refused | refused |
| CRC of IEND broken | refused | decoded | refused | refused | refused |
| CRC of gAMA broken | gAMA left out, decoded | decoded | refused | refused | refused |
| no IEND | refused | refused | refused | refused | decoded |
| bytes after IEND | refused (`TrailingData`) | decoded | decoded | decoded | decoded |
| zlib data past the last row | decoded | decoded | refused | decoded | refused |
| half the rows | refused | refused | refused | refused | refused |

The broken-input corpora of [png/docs/robustness.md](../png/docs/robustness.md)
(typst's 29,351 damaged seeds, image-png's 1,211 fuzzing files and libspng's 28
crashers), each decoder under a 2 GiB limit on the address space, and the
crashes and hangs of each:

| Decoder | Damaged seeds (29,351) | image-png's files (1,211) | libspng's files (28) |
|---|---|---|---|
| gaato/png `Decoder` | none: 3,540 decoded, the others refused | none | none |
| gaato/png `decode` | none: 3,880 decoded; 350 refused at the header with `LimitExceeded(Output)`, their IHDR claiming more than 512 MiB of rows, each at a peak of 3.2 to 5.3 MiB | none: 6 refused the same way, at 3.4 to 3.6 MiB | none |
| moonbitlang/typst 0.1.9 | none: 9,779 decoded | none | none |
| gmlewis/image 0.17.18 | 892 hang, 725 of them cut short (`trunc`): still running after 5 s, at under 2 MiB (a sample of 11 still after 30 s); 8 crash allocating the image IHDR claims (1.0 to 1.6 GiB, refused under a 3 GiB limit); 192 decode (35 of them in more than a second) to an indexed image with an index past its palette, on which its `at` aborts | 1 hangs | none |
| bikallem/image 0.1.0 | 34 crash: damaged image data of a 1.5 KB, 300 × 200 seed makes its buffer of inflated data (bikallem/blit's `Buffer`) grow past the limit, and past a 3 GiB one (with none, 1.3 GiB after two minutes, when it was stopped); 4 crash allocating the image IHDR claims (1.0 to 1.3 GiB, refused under a 3 GiB limit) | none | none |
| mizchi/image 0.4.3 | 138 abort inside `decode_png` (one traced: an array of the RGBA image's size, width × height × 4 in 32-bit arithmetic, which the runtime cannot make); 32 crash allocating that image (29 refused under a 3 GiB limit, after 1.0 to 1.8 GiB) | 3 abort, the same way | none |

A crash is the process killed by a signal (`SIGSEGV` when an allocation fails
under the limit, `SIGABRT` when the runtime aborts), a hang a case that writes
no line in 5 s; every case of each was run again on its own to tell.
gmlewis/image, which hangs on so many, ran each damaged seed in a process of
its own (`--dump` writes them to files), first for 1 s, then the ones that ran
out for 5 s. Of the damaged seeds, gmlewis/image decodes 2,528 besides
those 192, bikallem/image 2,808 and mizchi/image 877, and refuses the others.

### Running it

From the repository root, after `moon build --release --target native`:

```sh
exe=_build/native/release/build/gaato/codec_bench/compare_png
# PngSuite (unpacked from conformance/pngsuite/), the APNG vectors, broken files:
$exe/corpus/corpus.exe typst suite pngsuite-dir
$exe/corpus/corpus.exe typst apng conformance/apng/image-png conformance/apng/wpt conformance/apng/wuffs
$exe/corpus/corpus.exe typst seeds typst.mbt/oracle/src/bin/png_corpus.txt
$exe/corpus/corpus.exe typst files image-png/fuzz/corpus/decode libspng/tests/crashers
# Peak memory of one decode:
/usr/bin/time -f '%M KB' $exe/memory/memory.exe gaato-stream image.png
```

The decoders are `gaato` (`decode`), `gaato-stream` (`Decoder`), `typst`,
`gmlewis` and `mizchi`; `memory` takes `gaato-decode` for `decode`, with
`max_output` as a third argument, and `read` and `none` for the baselines. Each line of `corpus` goes to stderr; when the
process dies, start it again with `--from` the next case, or run one case with
`--only`. The benchmarks:

```sh
MOON_CC=cc taskset -c 3 moon bench --release --target native bench/src/compare_png
```
