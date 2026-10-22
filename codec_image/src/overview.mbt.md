# gaato/codec_image

The contract of streaming image decoders in [codecs.mbt](https://github.com/gaato/codecs.mbt): a decoder is driven step by step, takes input in chunks of any size, writes whole rows into output slices the caller provides, and keeps its memory within the limits it was given. A step stops to report the image's header, the start and the end of each frame, the rows it wrote, and metadata it was asked for. Code written against `Decode` works with every image decoder that implements it, such as [`gaato/png`](https://mooncakes.io/docs/gaato/png).

## Install

```sh
moon add gaato/codec_image
```

## Usage

Write the loop that drives an image decoder once, against `Decode`. Each step consumes a prefix of the input and says why it stopped; a step that writes, writes whole rows of one pass of the current frame and answers `Rows`, and the accessors say where they lie. A slice must hold at least one row, which `room_needed()` measures.

```mbt check
///|
/// Hands each row of the image in `chunks` to `row`, with its pass and its
/// row in the pass.
fn[D : @codec_image.Decode] each_row(
  decoder : D,
  chunks : Array[Bytes],
  row : (Int32, Int32, BytesView) -> Unit,
) -> Unit raise {
  let mut out = FixedArray::make(0, b'\x00')
  for i, chunk in chunks {
    let mut input = chunk[:]
    for ;; {
      if out.length() < decoder.room_needed() {
        out = FixedArray::make(decoder.room_needed() * 16, b'\x00')
      }
      let status = decoder.step(
        input,
        out.mut_view(),
        end=i == chunks.length() - 1,
      )
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
    Array[Bytes],
    (Int32, Int32, BytesView) -> Unit,
  ) -> Unit raise = each_row
  ignore(drive)
}
```

Rows come out in the format's own layout (for PNG, packed samples, palette indices, 16-bit samples big-endian), and interlaced images pass by pass: row `r` of a pass lies at row `pass_y() + r * pass_dy()` of the frame, and its pixel `i` at column `pass_x() + i * pass_dx()`. Converting pixels, applying palettes, and assembling passes and frames into a picture are left to functions outside the decoders, which each format module provides for its own layout.

## Errors

A step raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s `CodecError(kind, message)`. This package re-exports it with `ErrorKind`, `Limit` and `Resource`, so it is the only import a consumer needs to name them. In a `catch` on a decoder's step, `CodecError(kind, message)` and the kinds match unqualified; elsewhere, qualify a constructor by its type, as in `@codec_image.CodecError::CodecError(kind, _)`.

A step that raises writes nothing: the rows and events before the error came out in the steps before it. Errors stick: later steps raise the same kind until `reset`.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/codec_image/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [The image contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md#images): every rule a decoder keeps, and the formats it was checked against

## License

Apache-2.0.
