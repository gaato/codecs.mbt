# gaato/png

A PNG and APNG decoder in pure MoonBit, for Native, JS, Wasm and Wasm GC. Use
it to load an image as RGBA for a texture or a thumbnail, or to read a large
image row by row as it arrives, without holding the whole picture.

It reads every color type and bit depth, interlaced or not, APNG's frames and
the ancillary chunks of the specification's third edition. It checks every
CRC and the zlib Adler-32: a bad one in a critical chunk is an error, and an
ancillary chunk with a bad one is dropped. The streaming decoder holds two rows and a zlib
decoder, however tall the image is. It decodes only: there is no PNG encoder.

## Install

```sh
moon add gaato/png
```

## Decode an image to RGBA

`decode` reads a whole image held in memory, checks it, deinterlaces it and
returns its rows in PNG's own layout. The image's `converter` turns a row into
RGBA, applying the palette and transparency.

```mbt check
///|
test "decode a whole image and read it as RGBA" {
  // 2 x 1, indexed-color, 2 bits a pixel: red at half alpha, then blue.
  let png = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x01\x02\x03\x00\x00\x00\x89\x4c\x97\x19\x00\x00\x00\x06\x50\x4c\x54\x45\xff\x00\x00\x00\x00\xff\x6c\xa1\xfd\x8e\x00\x00\x00\x01\x74\x52\x4e\x53\x80\xad\x5e\x5b\x46\x00\x00\x00\x0a\x49\x44\x41\x54\x78\xda\x63\x10\x00\x00\x00\x12\x00\x11\x08\xde\xbd\xc3\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82"
  assert_true(@png.is_signature(png))
  let image = @png.decode(png, max_output=1 << 20)
  let rgba = FixedArray::make(image.width * 4, b'\x00')
  image.converter.rgba8(image.row(0), image.width, rgba.mut_view())
  assert_eq(Bytes::from_array(rgba[:]), b"\xff\x00\x00\x80\x00\x00\xff\xff")
}
```

`decode` refuses an image whose rows would take more than `max_output` bytes,
512 MiB by default, before allocating anything: a header of a few dozen bytes
can claim gigabytes. For an APNG, `decode` returns the default image.

The `Converter` offers three layouts:

- `rgba8`: 8 bits per channel. Smaller samples are widened, and 16-bit ones
  rounded.
- `rgba16`: 16 bits per channel, big-endian.
- `expanded`: palette to RGB or RGBA and gray widened to 8 bits, with 16 bits
  kept. This is the shape libpng's EXPAND gives.

## Stream rows as they arrive

`Decoder` implements [`gaato/codec_image`](https://mooncakes.io/docs/gaato/codec_image).
Each step consumes a prefix of the input and says why it stopped: `Header`
(size known), `Frame`, `Rows` (whole rows written), `FrameEnd` (the frame's
data passed every check), `Done`, or that it needs input or room. Pass
`end=true` once the source has run dry, with an empty input if need be, so
that a cut image, or an empty source, raises `Truncated`.

```mbt check
///|
/// The rows of the PNG image that `read` hands over, `None` once it has no
/// more, one after another.
fn rows_of(read : () -> Bytes?) -> Bytes raise {
  let decoder = @png.Decoder()
  let rows = Buffer()
  let mut out = FixedArray::make(0, b'\x00')
  for ;; {
    let piece = read()
    let end = piece is None
    let mut input = piece.unwrap_or(b"")[:]
    for ;; {
      // A slice must hold at least one row: `room_needed` says how long.
      if out.length() < decoder.room_needed() {
        out = FixedArray::make(decoder.room_needed() * 16, b'\x00')
      }
      let status = decoder.step_into(input, out, end~)
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
}

///|
/// A source that hands over `pieces` one by one, then `None`.
fn pieces_of(pieces : Array[Bytes]) -> () -> Bytes? {
  let mut next = 0
  () => {
    if next < pieces.length() {
      next += 1
      Some(pieces[next - 1])
    } else {
      None
    }
  }
}

///|
test "decode a 2 x 2 grayscale image in two pieces" {
  let png = b"\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52\x00\x00\x00\x02\x00\x00\x00\x02\x08\x00\x00\x00\x00\x57\xdd\x52\xf8\x00\x00\x00\x0e\x49\x44\x41\x54\x78\xda\x63\x60\xf8\xcf\xd0\xe0\x00\x00\x05\x42\x01\xc0\x6d\x5e\x78\xa0\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82"
  let rows = rows_of(pieces_of([png[:30].to_owned(), png[30:].to_owned()]))
  assert_eq(rows, b"\x00\xff\x80\x40")
}
```

After `Header`, `width()`, `height()`, `bit_depth()`, `color_type()` and
`interlaced()` describe the image, so you can refuse it before any rows are
decoded. `Decoder::converter()` gives a `Converter` for the streamed rows.

Rows come out in PNG's layout without the filter byte: samples under 8 bits
packed, palette indices as they are, 16-bit samples big-endian. An interlaced
image arrives in Adam7's seven passes. Row `r` of a pass is row
`pass_y() + r * pass_dy()` of the image. `scatter(...)` places a pass's row into
an image row. Rows are handed out before the CRCs that cover them are checked,
so treat them as provisional until `FrameEnd`.

## APNG

Each frame of an animation is a `Frame`, its rows, then `FrameEnd`. After
`Frame`, read the frame's rectangle (`frame_x()`, `frame_y()`, `frame_width()`,
`frame_height()`), its delay (`delay_numerator()`, `delay_denominator()`) and
its `dispose()` and `blend()` operations. These are given as the values to
apply (a denominator of 0 comes as 100). Compositing frames onto a canvas is
the caller's job, because the decoder holds no canvas. `animated()`,
`frame_count()` and `plays()` give what the animation control chunk says, and
`in_animation()` says whether the default image is part of the animation.
`Decoder(animation=false)` gives the default image only.

## Metadata chunks

Fixed-length chunks are read as they come. Their values are available from
`Frame` on: `transparency()`, `gamma()`, `chromaticities()`, `srgb_intent()`,
`coding_points()`, `physical_size()`, `background()` and others. The decoder
does not apply gamma or color management.

Other chunks are reported only when asked for. `Decoder(report=["tEXt", "iTXt", "iCCP", "eXIf"])`
hands out each one as a `Metadata` block once its CRC has passed, and
`metadata_type()` names it. iCCP, zTXt and iTXt come out inflated.
`parse_text` and `parse_time` read text and tIME blocks.

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

## Limits

| Option | Default | Notes |
| --- | --- | --- |
| `max_row_bytes` (`Decoder`) | 8,000,000 (a million pixels of 16-bit RGBA) | Up to 1,000,000,000. A longer row raises `LimitExceeded` at the step after `Header`, before allocation. Height is not bounded, because rows are handed out as they come. |
| `max_output` (`decode`) | 512 MiB | Up to 2^31 − 1. Larger images you trust can be read with `Decoder`. |
| `max_chunk_bytes` (`Decoder`) | 1 MiB | For reported chunks, which are held until their CRC passes. Chunks not asked for are skipped at any size. |
| `animation` (`Decoder`) | `true` | `false` reads APNG chunks as unknown ones. |

A streaming decoder holds 47,360 bytes until the size is known, then that plus
two rows. Asking for iCCP, zTXt or iTXt adds a second zlib decoder of 46,592
bytes.

## Errors

A step raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError(kind, message)`. The decoder follows libpng's defaults.

| Kind | When |
| --- | --- |
| `Truncated` | The input ends inside the image. |
| `Corrupt` | Not a PNG, chunks out of order, a malformed critical chunk, too little image data, a broken zlib stream, or an invalid APNG sequence. |
| `ChecksumMismatch` | A critical chunk's CRC (IHDR, PLTE, IDAT, IEND, fcTL, fdAT), or the zlib Adler-32. |
| `Unsupported` | A critical chunk the decoder does not know. |
| `TrailingData` | Bytes after IEND. With `until=EndOfMember`, the decoder stops after IEND and leaves them unread. |
| `LimitExceeded` | A row over `max_row_bytes`, a reported chunk over `max_chunk_bytes` (`resource: Memory`), or an image over `max_output` (`resource: Output`). |

A broken ancillary chunk does not fail the image. It is left out, as libpng
leaves it out, and `ignored_chunks()` counts it. A step that raises writes
nothing. **Errors stick:** every later step raises the same kind until
`reset()`.

## Links

- [Broken input](https://github.com/gaato/codecs.mbt/blob/main/png/docs/robustness.md):
  what the decoder does with corpora of broken files
- [Other MoonBit PNG decoders](https://github.com/gaato/codecs.mbt/blob/main/bench/README.md#other-moonbit-png-decoders):
  features, time and memory compared
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/png/RESOURCE_BOUNDS.md),
  [proofs](https://github.com/gaato/codecs.mbt/blob/main/png/PROOFS.md) and
  [test coverage](https://github.com/gaato/codecs.mbt/blob/main/png/TEST_COVERAGE.md)
- [The image contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md#images)
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/png/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0.
