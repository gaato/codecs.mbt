# gaato/lzw

LZW compression and decompression in pure MoonBit, for Native, JS, Wasm and
Wasm GC, in the four flavours files use: GIF's, TIFF's, PDF's and the `.Z` of
Unix `compress`. Use it inside a GIF, TIFF or PDF reader or writer, or to read
and write `.Z` files.

Each flavour has a streaming decoder and encoder that take input in chunks of
any size and write into output buffers you choose. They implement
[`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), so the same
loop drives the other codecs of [codecs.mbt](https://github.com/gaato/codecs.mbt).
Output is checked against the reference `compress` (ncompress 5.0), `gzip -d`
and other widely used LZW implementations.

## Install

```sh
moon add gaato/lzw
```

## Choose the flavour from the container

The flavours differ in bit order, when codes widen and how a stream ends, so
pick the one your container uses:

- **GIF**: `Format::gif(min_code_size)`. Take the minimum code size from the
  byte before the image data, and join the data sub-blocks before decoding.
  The decoded bytes are palette indices.
- **TIFF**: `Format::tiff()`.
- **PDF** (`/LZWDecode`): `Format::pdf()`, or `Format::pdf(early_change=false)`
  when the stream's parameters say `/EarlyChange 0`.
- **`.Z` files**: `Format::unix_compress()`. The stream includes its header,
  which sets the width and block mode. `stream_format()` reports them.

```mbt check
///|
test "compress and decompress" {
  let text = b"TOBEORNOTTOBEORTOBEORNOT"
  let gif = @lzw.Format::gif(8)
  let stream = @lzw.compress(text, gif)
  assert_eq(@lzw.decompress(stream, gif, max_output=16 * 1024 * 1024), text)
  let z = @lzw.Format::unix_compress()
  assert_eq(@lzw.decompress(@lzw.compress(text, z), z), text)
}

///|
test "decode what compress wrote" {
  // `printf 'hello hello hello' | compress -c -f`
  let z = b"\x1f\x9d\x90\x68\xca\xb0\x61\xf3\x06\x44\xc0\x81\x05\x0f\x12\x04"
  assert_eq(
    @lzw.decompress(z, @lzw.Format::unix_compress()),
    b"hello hello hello",
  )
}
```

`decompress` has no output cap unless you pass `max_output`. Set one for input
that comes from elsewhere.

## Decode a stream as it arrives

Pass `end=true` once the source has run dry, with an empty input if need be,
so that a stream cut short, or a source with nothing in it, raises
`Truncated`.

```mbt check
///|
/// Decodes what `read` hands over, `None` once it has no more, passing the
/// output to `write` as it is decoded.
fn decode_all(
  format : @lzw.Format,
  read : () -> Bytes?,
  write : (Bytes) -> Unit,
) -> Unit raise {
  let decoder = @lzw.Decoder(format)
  let out = FixedArray::make(64 * 1024, b'\x00')
  for ;; {
    let piece = read()
    let end = piece is None
    let mut input = piece.unwrap_or(b"")[:]
    for ;; {
      let status = decoder.step(input, out.mut_view(), end~)
      input = input[decoder.last_consumed():]
      write(Bytes::from_array(out[:decoder.last_produced()]))
      match status {
        Done => return
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
  }
}

///|
/// A source that hands over `pieces` one by one, then `None`.
fn pieces_of(pieces : Array[Bytes]) -> () -> Bytes? {
  let mut next = 0
  () => if next < pieces.length() {
    next += 1
    Some(pieces[next - 1])
  } else {
    None
  }
}

///|
test "decode a stream chunk by chunk" {
  let tiff = @lzw.Format::tiff()
  let stream = @lzw.compress(b"a strip of a TIFF image", tiff)
  let decoded = Buffer()
  let pieces = [stream[:5].to_owned(), stream[5:].to_owned()]
  decode_all(tiff, pieces_of(pieces), bytes => decoded.write_bytes(bytes))
  assert_eq(decoded.to_bytes(), b"a strip of a TIFF image")
}
```

- **Missing end codes.** Many writers leave GIF, TIFF and PDF streams without
  their end code. By default such a stream raises `Truncated`. Make the decoder
  with `allow_missing_end=true` to accept it.
- **Bytes after the end code.** `Decoder(format, until=EndOfMember)` stops right
  after the end code and leaves what follows unread. `.Z` has no end code and
  raises `Unsupported` in that mode.
- **Encoding.** `Encoder(format)` takes `Continue` and `Finish`. LZW cannot
  flush, so `Flush` raises `Unsupported`.

## How the flavours differ

| `Format` | Bits packed from | Codes | Widens | Ends |
|---|---|---|---|---|
| `gif(min_code_size)` | least significant | clear `1 << n`, end after it; `n + 1` to 12 bits | when the next code passes a power of two | at the end code |
| `tiff()`, `pdf()` | most significant | clear 256, end 257; 9 to 12 bits | one code early | at the end code |
| `pdf(early_change=false)` | most significant | as TIFF's | as GIF's | at the end code |
| `unix_compress(max_bits~, block_mode~)` | least significant | clear 256 in block mode, no end; 9 to `max_bits` (10 to 16) | as GIF's, with padding at each width change and clear | with the input |

## Limits

A decoder holds about 28 KiB for GIF, TIFF and PDF, and 448 KiB for 16-bit
`.Z` (`decoder_memory_bound(format)`). An encoder holds 48 KiB and 768 KiB
(`encoder_memory_bound(format)`). A `.Z` decoder refuses a stream wider than its
format's `max_bits` with `LimitExceeded`, since the table grows with the width.
`compress_bound(n, format)` is the most the encoder writes for `n` bytes.

## Errors

A malformed stream raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError(kind, message)`. The decoders never abort on bad input.

| Kind | When |
| --- | --- |
| `Truncated` | The input ends before the end code, or inside `.Z`'s header. |
| `Corrupt` | A first code that is not a literal, a code past the table, or a `.Z` header that is not one. |
| `TrailingData` | Bytes after the end code. |
| `LimitExceeded` | A `.Z` stream wider than `max_bits` (`resource: Memory`), or more than `max_output` (`resource: Output`). |
| `Unsupported` | A `.Z` header over 16 bits or of 9 bits; `.Z` under `EndOfMember`; `Flush`; a GIF minimum code size outside 1 to 8 or a byte it cannot code; a `.Z` `max_bits` outside 10 to 16. |

A step that raises first hands out the output before the error. **Errors
stick:** every later step raises the same kind until `reset()`.

## Not included

9-bit `.Z` (`compress` 5.0 writes it, but the common readers decode it
differently from how it was written, so no output is safe), the old
least-significant-bit TIFF LZW, and other LZW variants such as ZIP's shrink.
GIF sub-blocks and TIFF strips belong to those formats' readers.

## Links

- [GIF89a](https://www.w3.org/Graphics/GIF/spec-gif89a.txt),
  [TIFF 6.0](https://www.itu.int/itudoc/itu-t/com16/tiff-fx/docs/tiff6.pdf)
  (section 13), [PDF 2.0's LZWDecode](https://pdfa.org/resource/iso-32000-2/)
  and [ncompress](https://github.com/vapier/ncompress)
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/lzw/RESOURCE_BOUNDS.md)
  and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/lzw/TEST_COVERAGE.md)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md)
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/lzw/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0.
