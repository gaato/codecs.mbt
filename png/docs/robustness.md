# Broken input

What `gaato/png` makes of broken files, and where it parts from the png
crate, image-rs's decoder. The module [README](../src/overview.mbt.md) says
what a caller needs, and its Errors section gives the rules; this is the
background, with measurements that hold for the versions named.

The tests of the module and of the repository's conformance suite already
corrupt images at random and check every split of the input. The runs below
add files that other decoders were broken by, or were tested against.

## The corpora

| Corpus | Files | Source |
|---|---:|---|
| typst's damaged seeds | 29,351 | The damaged PNGs of [typst.mbt](https://github.com/moonbitlang/typst.mbt)'s oracle of the png crate (revision fce88c6f): 19 seeds (all five color types at bit depths from 1 to 16, interlaced or not, two larger images, an APNG, and the third edition's ancillary chunks spread among them), each with every bit of its first 64 bytes flipped, bits flipped further on and inside each chunk with its CRC fixed, cut at every length, chunks deleted, repeated, swapped, moved, emptied and grown, CRCs and the Adler-32 broken, the zlib stream cut or extended, unknown chunks inserted, and the header's dimensions changed |
| image-png's fuzzing corpus | 1,211 | `fuzz/corpus/decode` and `fuzz/corpus/buf_independent` of [image-png](https://github.com/image-rs/image-png) (revision b2f10c6) |
| libspng's crashers | 28 | `tests/crashers` of [libspng](https://github.com/randy408/libspng) (revision 46c81dc): 27 PNGs of its crash tests (chunks that claim huge lengths, a missing PLTE, a zero width, a broken iCCP, a bad CRC and Adler-32), and its `meson.build`, which is no PNG |

Each file is decoded whole three times: by the streaming `Decoder()`, with
its memory checked against the formula of
[RESOURCE_BOUNDS.md](../RESOURCE_BOUNDS.md) after every step; by
`Decoder(report=[...])`, asked for the text and metadata chunks, so that their
blocks and the second zlib decoder are counted too; and by `decode`, whose
image, converted to the png crate's EXPAND shape, is compared with what
typst 0.1.7's `decode_png` (a port of the png crate 0.18.1) gives.

## Results

No file crashed a decoder, made one hang, or took memory past the formula.
Every step either went on or raised one of the contract's errors.

The streaming decoder's outcomes:

| Outcome | Damaged seeds | image-png | libspng |
|---|---:|---:|---:|
| Decoded | 3,540 | 0 | 1 |
| `ChecksumMismatch` | 10,168 | 1,090 | 3 |
| `Corrupt` | 9,633 | 100 | 3 |
| `Truncated` | 5,290 | 20 | 21 |
| `Unsupported` | 428 | 0 | 0 |
| `LimitExceeded` (`Memory`) | 228 | 1 | 0 |
| `TrailingData` | 64 | 0 | 0 |

`LimitExceeded` comes from headers whose rows pass `max_row_bytes`. Asked to
report the text and metadata chunks, the decoder raises it for 37 more damaged
seeds and 7 of libspng's files, whose reported chunks claim more than
`max_chunk_bytes`; those were `Truncated` before, since the files end long
before the chunks would.

Against typst's `decode_png`:

| | Damaged seeds | image-png | libspng |
|---|---:|---:|---:|
| The same image | 3,797 | 0 | 1 |
| Both refuse the file | 19,502 | 1,211 | 26 |
| They differ | 6,052 | 0 | 1 |

`decode` reads the default image only, with APNG's chunks skipped as unknown
ones, so it decodes more of the damaged APNG than the streaming decoder,
which reads the animation.

## Where they differ

Every difference comes from one of the rules in the README's Errors section,
which follow libpng's defaults where the png crate is more lenient or, in a
few places, stricter.

| Cases | Damage | gaato/png | The png crate | Why |
|---:|---|---|---|---|
| 5,134 | The zlib stream's Adler-32 does not match its data: bits flipped inside the compressed data with the chunks' CRCs fixed, or the Adler-32 itself broken (libspng's `badadler.png` too) | `ChecksumMismatch` | Decodes: it does not check the Adler-32 by default | libpng checks it. With the CRCs fixed, the Adler-32 is the only check that sees the damage, and the rows it would hand out are not the image that was written |
| 412 | The file after the image data: cut before IEND ends, IEND's CRC broken, its type or length flipped, or IEND replaced by eight zero bytes | `Truncated`, `ChecksumMismatch`, `Unsupported` or `Corrupt` | Decodes: it stops after the image data and does not read IEND | `Done` says the whole file was read and checked. With `end=true`, a file that ends before IEND is cut short |
| 301 | A chunk type with a byte that is not a letter, before the image data | `Corrupt` | Skips the chunk, as an unknown ancillary one | The specification allows only letters; libpng refuses such a chunk |
| 68 | Bytes after IEND: a second IEND, a chunk moved past it, or garbage | `TrailingData` | Decodes: it does not look past the image data | Under the default `until=EndOfInput` the image ends the input, as for every codec of the repository; `until=EndOfMember` stops right after IEND and leaves the rest |
| 54 | The zlib stream broken or cut after the last row, or not ended in the IDAT chunks | `Corrupt` | Decodes: it stops inflating once it has every row | The decoder reads the zlib stream to its end, so that its Adler-32 is checked |
| 53 | APNG's chunks broken: an fcTL's rectangle outside the canvas, its operations, its length, a sequence number out of order, a second run of fdAT | `decode` gives the default image | Refuses the file | `decode` reads the still image and skips APNG's chunks, as a reader without APNG does; the streaming decoder, which reads the animation, raises `Corrupt` for all 53 |
| 17 | An ancillary chunk with values the specification does not allow, or out of place: a cICP with matrix coefficients or a full-range flag other than 0 and 1, a bKGD before PLTE | Leaves the chunk out and counts it in `ignored_chunks()` | Refuses the file | libpng treats these as benign errors in ancillary chunks: the image itself is intact |
| 7 | tRNS's gray level with bits set above the bit depth, in a 1-bit image | The pixels of that level are transparent | No pixel matches: it keeps the bits of the low byte | The bits above the bit depth are dropped, as libpng does when it expands rows and as WPT's `trns-high-bits-set.png` expects of browsers; the png crate drops only the high byte |
| 6 | A tRNS one byte too long, in a gray or truecolor image | Leaves the chunk out: no alpha channel | Reads its first bytes | A tRNS of the wrong length is not what the specification allows, and libpng leaves it out |

## Running it

The run is `bench/src/png_corpus`, a package of the repository's unpublished
benchmark module, which may read files. Its damage generator is a copy of
typst.mbt's, so that the cases are the ones typst checks itself against. The
corpora are not in the repository: fetch the three projects above and pass
their files, from the repository root:

```sh
moon run --release --target native bench/src/png_corpus -- \
  --seeds typst.mbt/oracle/src/bin/png_corpus.txt \
  image-png/fuzz/corpus/decode image-png/fuzz/corpus/buf_independent \
  libspng/tests/crashers
```

It prints the tallies for each corpus, a `CONTRACT` line for any file on which
the decoder broke its contract or its memory bound, and with `--list` a line
for each file on which the two decoders differ, with both errors.
