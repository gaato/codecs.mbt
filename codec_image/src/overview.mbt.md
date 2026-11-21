# gaato/codec_image

The streaming interface for image decoders in
[codecs.mbt](https://github.com/gaato/codecs.mbt). Write code that reads an
image a row at a time once, then use it with any image decoder that implements
`Decode`. Interlaced images and animation frames are included. Memory stays
within the decoder's limits, however large the image is, so a server can make
thumbnails or check uploads without holding whole pictures.

This package defines the interface only. For a decoder, add
[`gaato/png`](https://mooncakes.io/docs/gaato/png), which also has helpers that
turn rows into RGBA. Use this package directly when you write code that should
work with any image decoder.

## Install

```sh
moon add gaato/codec_image
```

## Drive any image decoder

Each `step` consumes a prefix of the input and returns a `Status` that says
why it stopped:

| Status | What to do |
| --- | --- |
| `Header` | `width()` and `height()` are known. Size your canvas or refuse the image. |
| `Frame` | A frame starts. `frame_x()`, `frame_y()`, `frame_width()` and `frame_height()` place it on the canvas. |
| `Rows` | `rows_count()` whole rows of `row_bytes()` bytes each were written to the output. |
| `Metadata` | A metadata block you asked the decoder for is ready. |
| `FrameEnd` | The frame is complete and checked. |
| `Done` | The image is complete. |
| `NeedMoreInput` | Pass the next chunk. |
| `NeedMoreOutput` | Pass an output slice of at least `room_needed()` bytes. |

Pass `end=true` once the source has run dry, with an empty input if need be,
so that a cut image, or an empty source, raises `Truncated`.

```mbt check
///|
/// Hands each row of the image that `read` hands over, `None` once it has no
/// more, to `row`, with its pass and its row in the pass.
fn[D : @codec_image.Decode] each_row(
  decoder : D,
  read : () -> Bytes?,
  row : (Int32, Int32, BytesView) -> Unit,
) -> Unit raise {
  let mut out = FixedArray::make(0, b'\x00')
  for ;; {
    let piece = read()
    let end = piece is None
    let mut input = piece.unwrap_or(b"")[:]
    for ;; {
      if out.length() < decoder.room_needed() {
        out = FixedArray::make(decoder.room_needed() * 16, b'\x00')
      }
      let status = decoder.step(input, out.mut_view(), end~)
      input = input[decoder.last_consumed():]
      match status {
        Rows => {
          let bytes = Bytes::from_array(out[:decoder.last_produced()])
          for r in 0..<decoder.rows_count() {
            let at = r * decoder.row_bytes()
            row(
              decoder.pass(),
              decoder.rows_first() + r,
              bytes[at:at + decoder.row_bytes()],
            )
          }
        }
        Done => return
        NeedMoreInput => break
        _ => ()
      }
    }
  }
}

///|
test "the loop takes any image decoder, a trait object too" {
  let drive : (
    &@codec_image.Decode,
    () -> Bytes?,
    (Int32, Int32, BytesView) -> Unit,
  ) -> Unit raise = each_row
  ignore(drive)
}
```

For a complete program on a real PNG, see the
[`gaato/png` README](https://mooncakes.io/docs/gaato/png).

## Rows and passes

Rows come out in the format's own layout: for PNG, packed samples, palette
indices, and 16-bit samples in big-endian order. Converting pixels, applying
palettes and assembling a picture are left to the format module, which provides
helpers for its layout.

An interlaced image arrives pass by pass. Row `r` of a pass lies at row
`pass_y() + r * pass_dy()` of the frame, and its pixel `i` at column
`pass_x() + i * pass_dx()`. A non-interlaced image has only pass 0. Every pass
delivers all its rows in order before the next one begins.

## Errors

A step raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError(kind, message)`. This package re-exports it with `ErrorKind`,
`Limit` and `Resource`, so no other import is needed to name them. In a `catch`
around a step, `CodecError(kind, message)` and the kinds match unqualified.
Elsewhere, write `@codec_image.CodecError::CodecError(kind, _)`.

A step that raises writes nothing. The rows before the error came out in
earlier steps. **Errors stick:** every later step raises the same kind until
`reset()`. Call `reset()` before decoding another image with the same decoder.

## Links

- [The image contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md#images):
  every rule a decoder keeps, and the formats it was checked against
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/codec_image/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0.
