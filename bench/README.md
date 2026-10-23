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

## Compression codecs against other implementations

gaato/zstd, gaato/brotli and gaato/deflate measured against the other
MoonBit implementations of their formats on mooncakes.io, as of 2026-10-23:

| Package | Version | Formats compared |
|---|---|---|
| [Milky2018/zstd](https://mooncakes.io/docs/Milky2018/zstd) | 0.1.4 | zstd |
| [hustcer/fbr](https://mooncakes.io/docs/hustcer/fbr) | 0.8.2 | Brotli |
| [mizchi/brotli](https://mooncakes.io/docs/mizchi/brotli) | 0.2.2 | Brotli |
| [moonbit-community/flate](https://mooncakes.io/docs/moonbit-community/flate) | 0.10.0 | raw DEFLATE, zlib, gzip |
| [gmlewis/flate](https://mooncakes.io/docs/gmlewis/flate), [gmlewis/zlib](https://mooncakes.io/docs/gmlewis/zlib), [gmlewis/gzip](https://mooncakes.io/docs/gmlewis/gzip) | 0.36.17, 0.21.17, 0.34.17 | raw DEFLATE, zlib, gzip |
| [mizchi/zlib](https://mooncakes.io/docs/mizchi/zlib) (the pure package, not `mizchi/zlib/native`) | 0.4.10 | raw DEFLATE, zlib, gzip |
| [hustcer/fzip](https://mooncakes.io/docs/hustcer/fzip) | 0.8.8 | raw DEFLATE, zlib, gzip |
| [moonbitlang/async](https://mooncakes.io/docs/moonbitlang/async) `gzip` | 0.22.5 | gzip |

Ours are this repository's main on that date: gaato/zstd 0.3.1,
gaato/brotli 0.4.1 and gaato/deflate 0.1.0, with the changes under
[Unreleased] in their changelogs.

[bikallem/compress](https://mooncakes.io/docs/bikallem/compress) 0.3.4
(zstd, Brotli, raw DEFLATE, zlib, gzip) is not compared: it does not build
with MoonBit 0.10.16 as published. Its module manifest is `moon.mod.json`,
which moon 0.1.20261016 refuses ("`moon.mod.json` ... is no longer
supported. Run `moon fmt` to migrate to `moon.mod`"), and its `zstd`,
`bzip2`, `lz4` and `snappy` use `try?`, which MoonBit has removed.

Measured on 2026-10-23 in a cloud VM: 4 vCPUs of an Intel Xeon @ 2.80 GHz
under KVM, Ubuntu 24.04, Linux 6.18; MoonBit 0.10.16 (moon and moonrun
0.1.20261016, moonc 0.10.16+b1a0e846e; moonrun for Wasm, Node 26.12.1 for
JS, GCC 13.3 for Native), timed runs pinned to one CPU and run one at a time.
The references are zstd 1.5.7, brotli 1.2.0 and Node's zlib
1.3.2.1-motley-456ae73 (the versions matter: zstd 1.5.5 refuses one of
zstd's own test vectors). The speed tables are the exception: they were
measured on an Intel Core i5-10400F (openSUSE Tumbleweed, Linux 7.2.11, GCC
16.2.1 for Native, the rest the same), whose times vary much less from run
to run than the VM's (see Speed). Peak memory also depends on the machine.

The packages are called through `src/compare`, one adapter each, the way
their READMEs show: their one-shot call for a whole input, and their
streaming API, if they have one, for input in pieces. `src/compare_check`,
`src/compare_stream` and `src/compare_ratio` are executables over those
adapters, and `src/compare_speed` holds the benchmarks.

### Features

What each package offers, from its interface and source, with the limits
in its defaults. "Pieces in, caller's buffer out" means a decoder that takes
its input in pieces of any size and writes into a buffer the caller owns.

zstd:

| Package | Decoder, encoder | Pieces in, caller's buffer out | Memory and limits | Integrity checks | Targets |
|---|---|---|---|---|---|
| gaato/zstd | decoder | yes | the window, at most `2^max_window_bits` (27 by default), plus 256 KiB; `decompress(max_output=)` | content checksum (XXH64) | Native, JS, Wasm, Wasm GC |
| Milky2018/zstd | decoder, dictionaries; encoder with levels (3 by default) | input in pieces (`push`), output as new `Bytes` from each `pull` | the whole output; no window limit | content checksum (XXH64) | Native, JS, Wasm, Wasm GC |

Brotli (the format has no checksum):

| Package | Decoder, encoder | Pieces in, caller's buffer out | Memory and limits | Targets |
|---|---|---|---|---|
| gaato/brotli | decoder; encoder with one quality | yes | the window, at most 16 MiB (`max_window_bits`), plus at most 1.3 MiB of tables; `decompress(max_output=)` | Native, JS, Wasm, Wasm GC |
| hustcer/fbr | decoder; encoder, qualities 0 to 11 | input in pieces (`push`), output through a callback | the whole output, also when streaming; `max_output_size` 100 MiB and `max_input_size` 1 GiB by default | Native, JS, Wasm, Wasm GC |
| mizchi/brotli | decoder; encoder, quality 0 (stored) or one other mode | no | no limit to set | Native, JS, Wasm, Wasm GC |

DEFLATE, zlib and gzip:

| Package | Decoder, encoder | Pieces in, caller's buffer out | Memory and limits | Integrity checks | Targets |
|---|---|---|---|---|---|
| gaato/deflate | raw DEFLATE, zlib, gzip; levels 0 to 9; preset dictionaries; gzip header fields | yes | about 46 KiB, plus a gzip header's fields up to `max_header_bytes`; `decompress(max_output=)` | Adler-32, CRC-32, ISIZE, gzip header CRC | Native, JS, Wasm, Wasm GC |
| moonbit-community/flate | raw DEFLATE, zlib, gzip, ZIP; levels 0 to 9 and optimal parsing; zlib dictionaries; no access to a gzip header's fields | yes | the window when streaming; `inflate_all(max_output=)`; gzip and zlib `decompress` take no limit | Adler-32, CRC-32, ISIZE, gzip header CRC | Native, JS, Wasm, Wasm GC |
| gmlewis/flate, zlib, gzip | raw DEFLATE, zlib, gzip; an encoder without levels; zlib dictionaries | it pulls its input from a reader, into the caller's buffer | the window; no output limit | Adler-32, CRC-32, ISIZE, gzip header CRC | decoder: Native (on JS, Wasm and Wasm GC it overflows the stack on the 512 KiB text: `read_literal` and `copy_history` call each other for each match); encoder: all four |
| mizchi/zlib | raw DEFLATE, zlib, gzip, whole buffers; an encoder without levels; no preset dictionaries | no | `max_size` 256 MiB by default | Adler-32, CRC-32, ISIZE | Native, JS, Wasm, Wasm GC |
| hustcer/fzip | raw DEFLATE, zlib, gzip, ZIP; levels 0 to 9; dictionaries | input in pieces (`push`), output through a callback; the input is kept and decoded at the last push | `max_output_size` 100 MiB and `max_input_size` 1 GiB by default; inputs over a third of `max_output_size` are refused | Adler-32, CRC-32, ISIZE, gzip header CRC | Native, JS, Wasm, Wasm GC |
| moonbitlang/async `gzip` | gzip; decoder and encoder (the encoder was not measured) | an asynchronous reader, read into the caller's buffer | the window | CRC-32 and ISIZE of the first member | Native, JS (others not tried) |

### Correctness

Every decoder ran, on Native, over the same streams, and each answer was
compared with the reference's (`scripts/compare_codecs.mbtx`). These counts
are the VM's; a run on the i5-10400F, with the same reference
versions, gave the same answer on every stream:

- valid: the conformance suite's vectors (`conformance/src`), Brotli's
  `gen/window24_far` (a 16 MiB window), and every stream below that the
  reference still decodes, such as a corruption in a field no one checks
  (the decoder must give the reference's output);
- cut short: every vector cut to half its length and to one byte less;
- checks: a byte of the checksum, CRC-32, ISIZE, Adler-32 or gzip header CRC
  flipped, and zlib streams that name a dictionary (FDICT) decoded without
  it;
- crafted: the zstd frames the reference refuses (`zstd/testdata`), the
  malformed Brotli streams of `brotli/src/crafted_wbtest.mbt`, and the
  crafted DEFLATE, zlib and gzip streams zlib refuses;
- seeded: 300 seeded corruptions of the zstd and Brotli vectors, and the
  1,000 of each of `deflate/src/*/vectors_wbtest.mbt`, that the reference
  refuses.

What the reference makes of each stream made here was asked of it (`zstd
-d`, `brotli -d`, Node's zlib). A stream counts as invalid when the reference
refuses it, and is refused when the decoder raises; output with no error is
an acceptance. A crash is the process ending on the stream (a MoonBit abort,
exit status -6, or a segmentation fault, -11), a hang no answer within 60 s
with the stream run alone. Streams that zlib decodes with bytes left over are left out:
whether bytes after a stream are an error is a policy that differs between
decoders. The zstd and Brotli commands refuse such bytes, so for those
formats a decoder that ignores them disagrees with the reference.

zstd (36 valid, 318 invalid):

| Decoder | Valid decoded | Invalid refused | Cut short | Checks | Crafted | Seeded | Crashes | Hangs |
|---|---|---|---|---|---|---|---|---|
| gaato/zstd | 36 | 318 | 28/28 | 10/10 | 3/3 | 277/277 | 0 | 0 |
| Milky2018/zstd | 36 | 318 | 28/28 | 10/10 | 3/3 | 277/277 | 0 | 0 |

`gen/window30_declared`, a frame that declares a 1 GiB window, is left out
of the counts: `zstd -d` refuses it at its default limit (128 MiB), as
gaato/zstd does at its default `max_window_bits=27`; Milky2018/zstd has no
window limit and decodes it.

Brotli (81 valid, 359 invalid):

| Decoder | Valid decoded | Invalid refused | Cut short | Crafted | Seeded | Crashes | Hangs |
|---|---|---|---|---|---|---|---|
| gaato/brotli | 81 | 359 | 76/76 | 20/20 | 263/263 | 0 | 0 |
| hustcer/fbr | 81 | 358 | 76/76 | 19/20 | 263/263 | 0 | 0 |
| mizchi/brotli | 81 | 290 | 67/76 | 16/20 | 207/263 | 9 | 0 |

hustcer/fbr accepts bytes after the end of the stream when it decodes a
whole input (fed in pieces, it refuses them). mizchi/brotli aborts
(a panic, exit status -6) on 9 corrupt streams, among them the 47-byte
`quickfox.compressed` cut to 23 bytes; it accepts 9 streams cut short, and
padding after the last meta-block, an insert and a dictionary word past the
end of a meta-block, and data after the end. A large-window stream (`brotli
--large_window=25`, not RFC 7932; `brotli -d` decodes it) is refused by all
three.

Raw DEFLATE (370 valid, 716 invalid):

| Decoder | Valid decoded | Invalid refused | Cut short | Crafted | Seeded | Crashes | Hangs |
|---|---|---|---|---|---|---|---|
| gaato/deflate | 370 | 716 | 36/36 | 44/44 | 636/636 | 0 | 0 |
| moonbit-community/flate | 370 | 716 | 36/36 | 44/44 | 636/636 | 0 | 0 |
| gmlewis/flate | 370 | 615 | 34/36 | 42/44 | 539/636 | 0 | 0 |
| mizchi/zlib | 370 | 702 | 32/36 | 40/44 | 630/636 | 0 | 0 |
| hustcer/fzip | 370 | 684 | 36/36 | 37/44 | 611/636 | 5 | 0 |

zlib (32 valid, 1,063 invalid; with a preset dictionary, 3 valid and 3
invalid):

| Decoder | Valid decoded | Invalid refused | Cut short | Checks | Crafted | Seeded | Dictionary | Crashes | Hangs |
|---|---|---|---|---|---|---|---|---|---|
| gaato/deflate | 32 | 1,063 | 36/36 | 20/20 | 13/13 | 994/994 | 3 + 3 | 0 | 0 |
| moonbit-community/flate | 32 | 1,063 | 36/36 | 20/20 | 13/13 | 994/994 | 3 + 3 | 0 | 0 |
| gmlewis/zlib | 32 | 1,063 | 36/36 | 20/20 | 13/13 | 994/994 | 3 + 3 | 0 | 0 |
| mizchi/zlib | 32 | 1,061 | 36/36 | 20/20 | 11/13 | 994/994 | no API | 0 | 0 |
| hustcer/fzip | 32 | 1,054 | 36/36 | 20/20 | 13/13 | 985/994 | 3 + 3 | 0 | 0 |

gzip (112 valid, 1,111 invalid):

| Decoder | Valid decoded | Invalid refused | Cut short | Checks | Crafted | Seeded | Crashes | Hangs |
|---|---|---|---|---|---|---|---|---|
| gaato/deflate | 112 | 1,111 | 66/66 | 67/67 | 51/51 | 927/927 | 0 | 0 |
| moonbit-community/flate | 112 | 1,110 | 66/66 | 67/67 | 50/51 | 927/927 | 0 | 0 |
| gmlewis/gzip | 112 | 1,105 | 66/66 | 67/67 | 47/51 | 925/927 | 0 | 0 |
| mizchi/zlib | 105 | 1,098 | 66/66 | 66/67 | 47/51 | 919/927 | 0 | 0 |
| hustcer/fzip | 112 | 1,111 | 66/66 | 67/67 | 51/51 | 927/927 | 0 | 0 |
| moonbitlang/async | 72 | 1,075 | 64/66 | 63/67 | 45/51 | 903/927 | 0 | 0 |

What lies behind the misses, from the list the script prints:

- Raw DEFLATE that zlib refuses and others accept: an empty input and a
  stream cut inside a dynamic block's header (gmlewis/flate); a fixed-code
  block with no end of block and incomplete literal or distance codes
  (mizchi/zlib); incomplete and over-subscribed codes, an empty input and a
  stored block whose LEN and NLEN disagree (hustcer/fzip). The script lists each seeded
  corruption a decoder misses. hustcer/fzip aborts (exit
  status -6) on 5 streams, among them a fixed-code block with distance code
  31.
- gzip: gmlewis/gzip and mizchi/zlib accept the reserved FLG bits;
  mizchi/zlib does not check the header CRC (FHCRC) and refuses a second
  member ("Trailing data after gzip stream").
  moonbitlang/async refuses any header field (FNAME, FCOMMENT, FEXTRA,
  FHCRC, FTEXT) with `InvalidHeader`, and decodes the first member only,
  ignoring the rest, corrupt or not. moonbit-community/flate accepts text
  after the last member, which zlib refuses.
- zlib: mizchi/zlib accepts CINFO 8 and 15 (windows over 32 KiB).

### Streaming

Each streaming decoder decoded every stream above with its input fed one
byte at a time and, where it writes into the caller's buffer, a 1-byte
output buffer (`compare_codecs.mbtx check --pieces 1 1 --invalid`), its
output compared byte for byte with the reference's; then the benchmarks'
512 KiB text, as `zstd -3`, `brotli -q 9 -w 22`, Node's zlib at level 6 and
`gzip -6 -n` compress it, whole, in 4 KiB pieces (4 KiB output buffer) and 1
byte at a time (`compare_codecs.mbtx stream`). "Out at half" is how much of
the output had come out while only the first half of the input had gone in.

| Decoder | Output into | Valid streams, 1 byte at a time | Text in 4 KiB pieces: out at half | its time against whole | Text 1 byte at a time |
|---|---|---|---|---|---|
| gaato/zstd | caller's buffer | 36/36 | 25 % | 1.1× | 35 ms |
| Milky2018/zstd | its own `Bytes` per `pull` | 24/36: output repeated | 16 %, and 7,602,176 bytes out instead of 524,288 | 13.6× | no answer within 300 s |
| gaato/brotli | caller's buffer | 81/81 | 48 % | 1.1× | 138 ms |
| hustcer/fbr | callback | 81/81 | 0 % | 15× | 289 s |
| gaato/deflate (raw / zlib / gzip) | caller's buffer | 370/370, 32/32, 112/112 | 49 % | 1.1× | 59 ms (raw) |
| moonbit-community/flate | caller's buffer | 370/370, 32/32, 112/112 | 49 % | 1.2× | 46 ms |
| gmlewis/flate, zlib, gzip | caller's buffer (it pulls from a reader) | 370/370, 32/32, 112/112 | 44 % | 1.0× | 37 ms |
| hustcer/fzip | callback | 370/370, 32/32, 112/112 | 0 % | 1.0× | 16 ms |
| moonbitlang/async (gzip) | caller's buffer (an asynchronous reader) | 72/112, as whole | 49 % | 0.9× | 120 ms |

mizchi/brotli and mizchi/zlib take whole inputs only. The times are on
Native, the mean of 20 decodes (of one, 1 byte at a time). Fed one byte at a
time, every decoder refuses the same invalid streams as whole, but for
hustcer/fbr, which then also refuses bytes after the end of the stream.

- Milky2018/zstd's `Decompressor` decodes the frame again from its start at
  every `pull` and hands out again what it handed out before when the frame
  is not yet whole: fed in pieces, its output is longer than the stream's
  (14.5 times on the text). Its 12 failures over the vectors are of this
  kind.
- hustcer/fbr's stream gave out nothing for the text before its last piece;
  its README says that it hands out each meta-block once it is whole, and
  decodes an incomplete one again at every push, which is where the time
  in pieces goes.
- hustcer/fzip's streams keep their input until the last push and decode
  it then: nothing comes out before the end, and the input must fit in
  memory.

### Memory

The peak resident memory of `compare_stream` decoding 256 MiB (the 512 KiB
text 512 times), whole and in 64 KiB pieces into a 64 KiB buffer, measured
with `/usr/bin/time -f %M` (`compare_codecs.mbtx memory`). That is the
process's memory, not the decoder's alone: compare_stream reads the
compressed file whole first (zstd 2,463,691 bytes, 2.3 MiB; Brotli 134,935;
raw DEFLATE 71,016,308, 67.7 MiB; zlib 71,016,314; gzip 71,361,870), and
the runtime with a small decode, the 512 KiB text whole, takes 5.8 to 6.8
MiB (mizchi/brotli 23.2 MiB).

| Decoder | Whole | 64 KiB pieces |
|---|---:|---:|
| gaato/zstd | 521 MiB | 10.8 MiB |
| Milky2018/zstd | 519 MiB | 524 MiB, with 659 MiB of output (repeated) |
| gaato/brotli | 517 MiB | 12.9 MiB |
| hustcer/fbr | refuses: "output exceeds max_output_size" (100 MiB by default), at 249 MiB | the same, after 96 MiB of output, at 242 MiB |
| mizchi/brotli | 1,557 MiB | |
| gaato/deflate (raw / zlib / gzip) | 584 / 584 / 585 MiB | 72.6 / 72.6 / 72.9 MiB |
| moonbit-community/flate | 599 / 599 / 841 MiB | 72.6 / 72.7 / 73.0 MiB |
| gmlewis/flate, zlib, gzip | 584 / 584 / 585 MiB | 72.2 / 72.2 / 72.6 MiB |
| mizchi/zlib | 584 / 584 / 585 MiB | |
| hustcer/fzip | refuses: "input too large for safe allocation" (over a third of its 100 MiB output limit), at 140 MiB | the same, at the last push, with no output, at 212 MiB |
| moonbitlang/async (gzip) | 594 MiB | 73.4 MiB |

Whole, every decoder holds the 256 MiB output, and most a second copy while
they make `Bytes` of it. In pieces, the decoders that stream stay within
about 5 MiB of the input and the runtime: 10.8 MiB for gaato/zstd is 2.3
MiB of input, 6.6 MiB of runtime and small decode, and the 2 MiB window of
`zstd -3`; the DEFLATE formats' 72 to 73 MiB are mostly their 67.7 MiB
input. The refusals' messages are from the packages' sources; the run
records the error's type.

### Headers that claim a size

A decoder that allocates what a header claims before the data is there can
be made to take memory a short input does not justify. Four inputs of 9 to
25 bytes (`zstd_fcs`: a zstd frame header claiming 2^60 bytes of content in
a 128 MiB window, then a compressed block header of 128 KiB and nothing
more; `zstd_single`: a single-segment frame claiming 64 MiB, then 5 bytes;
`brotli_mlen`: a 16 MiB window and a 16 MiB uncompressed meta-block, then 5
bytes; `gzip_isize`: `hello` with ISIZE set to 2,147,483,632), and seven
small inputs that made decoders fail on the i5-10400F, were decoded whole
and in 4 KiB pieces, each run alone under a 1 GiB address-space limit
(`prlimit --as`) and a 30 s timeout, and again under 8 GiB if it ended
abnormally (`compare_codecs.mbtx claims`; the inputs are
[`fixtures.tsv`](compare/fixtures.tsv)). The
references refuse all four claims.

| Decoder | Peak on the four claims | Outcome |
|---|---|---|
| gaato/zstd, gaato/brotli, gaato/deflate (gzip) | 4.4 to 4.7 MiB | refused |
| Milky2018/zstd, moonbit-community/flate, gmlewis/gzip, mizchi/zlib, hustcer/fzip, moonbitlang/async | 4.4 to 4.5 MiB | refused |
| hustcer/fbr | 20.2 MiB on `brotli_mlen` | refused |
| mizchi/brotli | 132.4 MiB on `brotli_mlen` | an abort (signal 6), under either limit |

None of gaato's decoders allocates from a claimed size: the zstd window and
the Brotli window grow with the output (`ensure_space`), and a zstd block
buffer is at most 128 KiB, checked against the block limit first. A 4.5 MiB
peak is the process with nothing decoded. gmlewis/gzip, fed in pieces,
hands out `hello` before it refuses the trailer.

Of the other inputs, which the references all refuse but `hello.zst`:
mizchi/brotli aborts on `mizchi-brotli-alloc.br` (at 132.4 MiB) and
`mizchi-brotli-panic.br`; hustcer/fzip aborts on `fzip-dist31.deflate`, a
fixed-code block with distance code 31; hustcer/fbr and mizchi/brotli
accept `fbr-trailing.br`, an empty stream followed by a byte. No decoder
needed more than the 1 GiB limit, and none ran out of time.

### Speed

The mean time, in milliseconds, to decode the benchmarks' inputs (the 512
KiB text and the 128 KiB binary stream of `src/data_test.mbt`, made by
`zstd -3`, `brotli -q 9 -w 22` and `gzip -6 -n`; raw DEFLATE is the data
inside the gzip member), and to compress what they decode to, over three
runs on each target taken in turn, pinned to one CPU (`compare_codecs.mbtx
speed`, which runs `src/compare_speed` with `moon bench --release`). Each
benchmark runs for 300 ms before it is measured, and the first measurement
of a run is taken twice and the first one not counted: on JS and Wasm the
first benchmarks of a run otherwise take up to twice as long. "steps" is
the streaming decoder into a 64 KiB buffer, as `src/bench_test.mbt` calls
it; the other rows are each package's one-shot call (ours is `decompress`).

These times are the Intel Core i5-10400F's (the cloud VM's differed
between runs by 19 % of a benchmark's mean at the median and by up to
167 %, too much to compare packages by).

Decoding (text, then binary, per target):

| Decoder | Native | | Wasm | | Wasm GC | | JS | |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| gaato/zstd steps | 4.60 | 1.04 | 12.8 | 2.47 | 6.69 | 1.47 | 23.9 | 5.16 |
| gaato/zstd `decompress` | 4.85 | 1.07 | 12.8 | 2.42 | 7.76 | 1.68 | 31.0 | 6.63 |
| Milky2018/zstd | 9.41 | 5.83 | 26.5 | 12.3 | 17.9 | 11.1 | 42.9 | 16.2 |
| gaato/brotli steps | 3.48 | 1.75 | 11.2 | 5.75 | 6.39 | 2.83 | 12.7 | 4.49 |
| gaato/brotli `decompress` | 3.54 | 1.71 | 11.3 | 6.04 | 7.50 | 3.07 | 18.9 | 5.92 |
| hustcer/fbr | 3.15 | 1.55 | 7.35 | 4.43 | 7.21 | 3.45 | 21.0 | 9.71 |
| mizchi/brotli | 5.38 | 2.92 | 18.2 | 7.80 | 10.3 | 7.38 | 32.7 | 25.1 |
| gaato/deflate steps | 1.45 | 0.50 | 1.91 | 0.71 | 1.81 | 0.62 | 3.27 | 1.03 |
| moonbit-community/flate steps (`Inflater`) | 1.62 | 0.54 | 5.84 | 3.75 | 4.75 | 3.02 | 4.69 | 3.25 |
| gaato/deflate `decompress` | 1.50 | 0.52 | 2.01 | 0.73 | 2.87 | 0.88 | 10.2 | 2.65 |
| moonbit-community/flate `inflate_all` | 1.91 | 0.94 | 5.45 | 2.21 | 4.37 | 1.93 | 6.38 | 2.59 |
| gmlewis/flate | 10.2 | 4.18 | stack overflow | | stack overflow | | stack overflow | |
| mizchi/zlib | 3.31 | 1.24 | 7.67 | 3.56 | 5.63 | 2.58 | 31.2 | 15.7 |
| hustcer/fzip | 2.32 | 0.59 | 4.80 | 2.71 | 3.77 | 1.10 | 10.6 | 2.64 |

gmlewis/flate's decoder is not timed on JS, Wasm and Wasm GC (see
Features). Where another package is faster: hustcer/fbr decodes Brotli 1.5
times as fast as gaato/brotli on Wasm and about as fast on Native and Wasm
GC; moonbit-community/flate's `inflate_all` is faster than gaato/deflate's
`decompress` on JS, where gaato/deflate's streaming decoder is the fastest
of the three. moonbitlang/async's gzip decoder was timed with
`compare_stream` on Native only (its API is asynchronous, which `moon
bench` does not run): 4.05 ms for the text's gzip member, against 2.40 ms
for gaato/deflate's gzip `decompress` in the same run (`compare_codecs.mbtx
stream`).

Encoding (text, then binary), at each package's default level and, if it
has another, its highest:

| Encoder | Native | | Wasm | | Wasm GC | | JS | |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| gaato/brotli (one quality) | 14.0 | 4.65 | 40.0 | 12.2 | 16.4 | 5.52 | 31.3 | 9.82 |
| hustcer/fbr, quality 11 (its default) | 2,467 | 193 | 7,697 | 607 | 2,607 | 199 | 4,233 | 297 |
| mizchi/brotli, quality 1 (its default) | 14.0 | 2.39 | 38.3 | 7.15 | 24.9 | 2.53 | 16.4 | 3.80 |
| gaato/deflate, level 6 | 13.5 | 3.25 | 35.2 | 11.4 | 22.3 | 5.86 | 40.6 | 11.2 |
| gaato/deflate, level 9 | 38.9 | 6.74 | 87.3 | 17.4 | 70.6 | 10.9 | 116 | 18.2 |
| moonbit-community/flate, level 6 | 11.4 | 3.44 | 18.8 | 6.77 | 22.4 | 5.80 | 28.9 | 11.2 |
| moonbit-community/flate, level 9 | 35.5 | 7.89 | 47.6 | 11.7 | 65.6 | 13.7 | 72.7 | 18.3 |
| gmlewis/flate (no levels) | 195 | 88.3 | 477 | 218 | 164 | 72.3 | 425 | 190 |
| mizchi/zlib (no levels) | 52.5 | 6.22 | 103 | 13.8 | 48.4 | 7.90 | 71.4 | 13.6 |
| hustcer/fzip, level 6 | 18.3 | 0.03 | 80.3 | 0.06 | 22.1 | 0.31 | 36.9 | 1.71 |
| hustcer/fzip, level 9 | 34.3 | 0.03 | 201 | 0.06 | 45.7 | 0.31 | 69.1 | 1.75 |

hustcer/fzip stores the binary input (131,087 bytes), which accounts for its
times there. mizchi/brotli's stream for the binary input does not decode
(below); those times are for writing it. moonbit-community/flate at level 6
compresses the text faster than gaato/deflate at level 6 on Native, Wasm and
JS (on the binary input it is slightly slower on Native), and
mizchi/brotli compresses the binary input faster than gaato/brotli, at a
worse ratio and with streams that do not always decode.

### Compression ratio

Sizes in bytes, measured with `compare_codecs.mbtx ratio --time 0`: the
benchmarks' text (524,288 bytes) and binary stream (131,072), the six files
of the [Silesia corpus](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia)
that [deflate/docs/compression.md](../deflate/docs/compression.md) uses
(128,070,243 bytes), all twelve (211,938,580), and the eleven files of the
[Canterbury corpus](https://corpus.canterbury.ac.nz/) (2,810,784), each file
matching [`corpora.tsv`](compare/corpora.tsv). Every
stream was decoded back to its input by the reference (Node's zlib, `brotli
-d`), and by gaato/deflate or gaato/brotli; where one did not decode, it says
so. These sizes do not depend on the machine: the i5-10400F's were the same.

Raw DEFLATE:

| Encoder | Text | Binary | Silesia, six | Silesia | Canterbury |
|---|---:|---:|---:|---:|---:|
| gaato/deflate, level 6 | 147,539 | 116,486 | 34,874,148 | 67,559,935 | 722,392 |
| gaato/deflate, level 9 | 139,738 | 116,209 | 34,461,284 | 66,769,220 | 695,675 |
| moonbit-community/flate, level 6 | 151,935 | 116,559 | 35,410,992 | 68,296,237 | 738,649 |
| moonbit-community/flate, level 9 | 139,753 | 116,233 | 35,015,440 | 67,592,154 | 726,806 |
| gmlewis/flate | 179,495 | 121,133 | 42,313,099 | 81,458,796 | 877,806 |
| mizchi/zlib | 184,549 | 118,073 | 39,724,845 | 78,600,808 | 886,244 |
| hustcer/fzip, level 6 | 153,599 | 131,087 | 40,683,016 | 83,865,727 | 775,407 |
| hustcer/fzip, level 9 | 153,516 | 131,087 | 40,677,505 | 83,855,167 | 773,098 |

Brotli (Canterbury without `ptt5`, 2,297,568 bytes, because hustcer/fbr's
encoder aborts on that file):

| Encoder | Text | Binary | Canterbury without `ptt5` | Canterbury |
|---|---:|---:|---:|---:|
| gaato/brotli | 158,878 | 94,218 | 590,909 | 645,860 |
| hustcer/fbr, quality 11 | 131,556 | 92,867 | 534,975 | aborts on `ptt5` (exit status -6) |
| mizchi/brotli, quality 1 | 169,007 | does not decode | 777,152, `asyoulik.txt` does not decode | not totalled: `asyoulik.txt` does not decode |
| `brotli -q 4` | 160,100 | 98,397 | 581,371 | 634,667 |
| `brotli -q 9 -w 22` | 134,529 | 86,756 | 495,359 | 543,558 |
| `brotli -q 11` | 122,831 | 83,951 | 449,725 | 490,664 |

mizchi/brotli's encoder writes streams that `brotli -d` refuses ("corrupt
input") for the binary input and for `asyoulik.txt`, 2 of the 13 files. The
`brotli` rows are brotli 1.2.0 given each file by name.
Milky2018/zstd's encoder, for reference (gaato/zstd has none): at its
default level 3 it writes raw blocks, 524,309 bytes for the text; at levels
10, 19 and 22 it writes about 286,150. No command of the script measures
them. `zstd -3` (1.5.7, the file named) writes 148,537 bytes for
the text.

### Running them again

From the repository root, with the toolchain of `moonbit-version` and the
reference versions above on `PATH`, and `N` a CPU the process may use
(`taskset -pc $$` lists them):

```sh
moon run scripts/compare_codecs.mbtx                  # correctness
moon run scripts/compare_codecs.mbtx -- check --pieces 1 1 --invalid
moon run scripts/compare_codecs.mbtx -- claims
taskset -c N moon run scripts/compare_codecs.mbtx -- stream --timeout 300
taskset -c N moon run scripts/compare_codecs.mbtx -- memory --timeout 300
moon run scripts/compare_codecs.mbtx -- ratio --format deflate --time 0 --corpus SILESIA --corpus CANTERBURY
moon run scripts/compare_codecs.mbtx -- ratio --format brotli --time 0 --corpus CANTERBURY
taskset -c N moon run scripts/compare_codecs.mbtx -- speed --runs 3
```

They need the zstd, brotli, gzip and node commands, `/usr/bin/time` and
`prlimit`. Other reference versions can give other verdicts, and the
corpora's files should match
[`corpora.tsv`](compare/corpora.tsv). The script's
opening comment lists its options.
