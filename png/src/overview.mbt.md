# gaato/png

A streaming PNG decoder in pure MoonBit, for Native, JS, Wasm and Wasm GC. It takes input in chunks of any size, writes whole rows into output slices you provide, checks every CRC and the zlib stream's Adler-32, and holds two rows and a zlib decoder, whatever the image's height.

The module is being written. The decoder reads every color type and bit depth, interlaced or not, with the ancillary chunks of the specification's third edition and APNG's frames; functions that convert rows to RGBA, and that put frames together, come later.

## Install

```sh
moon add gaato/png
```

## Usage

`Decoder` implements the image contract of [`gaato/codec_image`](https://mooncakes.io/docs/gaato/codec_image). Each step consumes a prefix of the input and says why it stopped: the image's header is known (`Header`), its frame begins (`Frame`), whole rows were written (`Rows`), the frame's data has passed every check (`FrameEnd`), the image is complete (`Done`), or it needs input or room. Pass `end=true` with the last input, so that an image cut short raises `Truncated` instead of ending quietly.

```mbt check
///|
/// The rows of a PNG image given in `chunks`, one after another.
fn rows_of(chunks : Array[Bytes]) -> Bytes raise {
  let decoder = @png.Decoder()
  let rows = Buffer()
  let mut out = FixedArray::make(0, b'\x00')
  for i, chunk in chunks {
    let mut input = chunk[:]
    for ;; {
      // A slice must hold at least one row: `room_needed` says how long.
      if out.length() < decoder.room_needed() {
        out = FixedArray::make(decoder.room_needed() * 16, b'\x00')
      }
      let status = decoder.step_into(input, out, end=i == chunks.length() - 1)
      input = input[decoder.last_consumed():]
      match status {
        Rows =>
          rows.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
        Done => return rows.to_bytes()
        NeedMoreInput => break
        _ => ()
      }
    }
  }
  rows.to_bytes()
}

///|
test "decode a 2 x 2 grayscale image in two pieces" {
  let png = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x02\x08\x00\x00\x00\x00\x57\xdd\x52\xf8\x00\x00\x00\x0e\x49\x44\x41\x54\x78\xda\x63\x60\xf8\xcf\xd0\xe0\x00\x00\x05\x42\x01\xc0\x6d\x5e\x78\xa0\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82"
  let rows = rows_of([png[:30].to_owned(), png[30:].to_owned()])
  assert_eq(rows, b"\x00\xff\x80\x40")
}
```

`step_into` writes into a whole `FixedArray` with bulk copies of the rows; `step`, the contract's method, writes into any `MutArrayView`.

After `Header`, `width()`, `height()`, `bit_depth()`, `color_type()` and `interlaced()` describe the image; from `Frame`, `palette()` holds an indexed-color image's palette.

## Rows

Rows come out in PNG's own layout, without the filter type byte: samples packed when they have fewer than 8 bits, palette indices as they are, 16-bit samples big-endian. After `Rows`, `rows_count()` rows of `row_bytes()` bytes each were written, starting at row `rows_first()` of pass `pass()`.

An interlaced image comes out in Adam7's seven passes, each a lattice of the image: row `r` of the pass is row `pass_y() + r * pass_dy()` of the image, and its pixel `i` is column `pass_x() + i * pass_dx()`. A pass with no pixels is skipped. An image that is not interlaced is the one pass 0, with a lattice of 0, 0, 1, 1.

An index past the end of the palette is left in the row as it is; the specification shows such a pixel as opaque black.

## Ancillary chunks

The fixed-length chunks are read as they come, and their values returned from `Frame` on: `transparency()` (tRNS), `significant_bits()` (sBIT), `gamma()` (gAMA), `chromaticities()` (cHRM), `srgb_intent()` (sRGB), `coding_points()` (cICP), `mastering_display()` (mDCV), `light_level()` (cLLI), `physical_size()` (pHYs) and `background()` (bKGD). The decoder does not apply them: gamma, color spaces and which of cICP, iCCP, sRGB and cHRM wins are the caller's.

The others are reported only when asked for: `Decoder(report=["iCCP", "eXIf", "tEXt", "zTXt", "iTXt"])` hands out each chunk of those types as one block of `Metadata`, once its CRC has passed, with `metadata_type()` naming it. iCCP's profile, zTXt's text and iTXt's compressed text come out inflated: iCCP's block is the profile's name, a NUL and the profile; zTXt's is the keyword, a NUL and the text, as tEXt's is; iTXt's has its compression flag and method set to 0. Any ancillary type can be asked for, unknown ones too; a fixed-length chunk asked for is both read and reported.

```mbt check
///|
test "report the text chunks" {
  let png = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x00\x00\x00\x00\x3a\x7e\x9b\x55\x00\x00\x00\x0e\x74\x45\x58\x74\x41\x75\x74\x68\x6f\x72\x00\x73\x6f\x6d\x65\x6f\x6e\x65\xbf\x83\xd1\xc0\x00\x00\x00\x0a\x49\x44\x41\x54\x78\xda\x63\x60\x00\x00\x00\x02\x00\x01\xe5\x27\xde\xfc\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82"
  let decoder = @png.Decoder(report=["tEXt"])
  let out = FixedArray::make(256, b'\x00')
  let mut rest = png[:]
  let texts = []
  for ;; {
    match decoder.step_into(rest, out, end=true) {
      Metadata =>
        texts.push(
          "\{decoder.metadata_type()}: \{Bytes::from_array(out[:decoder.last_produced()])}",
        )
      Done => break
      _ => ()
    }
    rest = rest[decoder.last_consumed():]
  }
  inspect(
    texts.join("\n"),
    content=(
      #|tEXt: b"Author\x00someone"
    ),
  )
}
```

## APNG

An animated image's frames come one after another, each a `Frame`, its rows, and `FrameEnd`. `frame_x()`, `frame_y()`, `frame_width()` and `frame_height()` place the frame on the canvas, and its rows are as wide as the frame; `delay_numerator()` and `delay_denominator()` say how long it is shown, `dispose()` what to do with its rectangle afterwards, `blend()` how its pixels go on the canvas. These are the values to apply: a delay's denominator of 0 comes as 100, and the first frame's dispose op of PREVIOUS as `Background`, as the specification says. Putting frames together is the caller's: the decoder holds no canvas.

The default image (IDAT) is the first `Frame`; `in_animation()` says whether it is part of the animation (an fcTL comes before it) or only what a reader without APNG shows. `animated()`, `frame_count()` and `plays()` give what acTL says. With `Decoder(animation=false)` the decoder reads APNG's chunks as unknown ones and gives the default image only.

## Limits

`Decoder(max_row_bytes=...)` bounds a row's bytes: 8,000,000 by default (a million pixels of 16-bit RGBA), at most 1,000,000,000. An image with longer rows raises `LimitExceeded` with `resource: Memory` and the row's bytes, at the step after `Header`, before anything is allocated for it, so you can look at the size first. The height is not bounded: rows are handed out as they come.

`memory_usage()` is 47,360 bytes (the zlib decoder and the palette) until the step after `Header`, then 47,360 + 2 × (1 + row bytes).

A reported chunk is held until its CRC has passed, so `Decoder(max_chunk_bytes=...)` bounds it: 1 MiB by default, at most 100,000,000. A reported chunk longer than that raises `LimitExceeded` with `resource: Memory` and the chunk's length, and one that inflates to more raises it with no length. Asking for iCCP, zTXt or iTXt adds a second zlib decoder, 46,592 bytes, which the decoder holds only then: APNG allows text between the image data chunks of one frame, in the middle of their zlib stream. Chunks that are not asked for are only read through their CRC, whatever their size.

## Errors

A step raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s `CodecError(kind, message)`. The decoder follows libpng's defaults:

- `Truncated`: the input ends inside the image.
- `Corrupt`: not a PNG signature, an IHDR that describes no image, chunks out of order (IHDR not first, IDAT chunks not consecutive or missing, an indexed-color image without PLTE before IDAT), a malformed chunk, a filter type past 4, too little image data, or a zlib stream that does not end in the IDAT chunks.
- `ChecksumMismatch`: the CRC of IHDR, PLTE (in an indexed-color image), IDAT or IEND, or the zlib stream's Adler-32.
- `Unsupported`: a critical chunk the decoder does not know.
- `TrailingData`: bytes after IEND. With `until=EndOfMember` the decoder stops right after IEND instead, and what follows is `input[last_consumed():]`.
- An error inside the zlib stream keeps its kind, with `IDAT` in the message: `Corrupt` for malformed data, and `DictionaryRequired` for a stream that names a preset dictionary.
- In an APNG, `Corrupt` too for a sequence number out of order, an fdAT without its fcTL, a frame without data, an fcTL outside the canvas or with an operation the specification does not define, a second acTL, and a count of frames other than acTL's; and `ChecksumMismatch` for the CRC of fcTL and fdAT, which an APNG needs as it needs IDAT. An acTL after IDAT or of no frames leaves the image still, as one without acTL is.

An ancillary chunk out of the place the specification gives it, a second copy of one that may come once, one whose CRC does not match, or one whose values the specification does not allow (a gAMA of 0, a cICP with matrix coefficients, a tRNS longer than the palette, a zTXt whose keyword is empty or whose zlib stream is broken, and so on, as libpng judges them) is left out, and `ignored_chunks()` counts it; a later valid copy is still read. The bits of tRNS's samples above the bit depth are dropped, as browsers and image-rs show such images, where libpng keeps them and warns. So is a PLTE that a grayscale image cannot use, a PLTE out of place in a truecolor image, and the data of an IEND that has some. Entries of a palette beyond what the bit depth can index are dropped. Inflated data past the last row, and bytes after the zlib stream, are dropped.

Rows come out as soon as they are decoded, before the CRCs and the Adler-32 that cover them, so `ChecksumMismatch` can follow rows you already have; `FrameEnd` comes once they have passed. A step that raises writes nothing: the rows before the error came out in the steps before it. Errors stick until `reset`.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/png/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [The image contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md#images) that `Decoder` keeps
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/png/RESOURCE_BOUNDS.md): every limit and the tests that hold it
- [Test coverage](https://github.com/gaato/codecs.mbt/blob/main/png/TEST_COVERAGE.md)

## License

Apache-2.0.
