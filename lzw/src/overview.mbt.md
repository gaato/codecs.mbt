# gaato/lzw

LZW in pure MoonBit, for Native, JS, Wasm and Wasm GC, in the four flavours files use: GIF's, TIFF's, PDF's and the .Z of Unix compress. A streaming decoder and encoder for each, held to weezl (the LZW of Rust's image crates), to compress (ncompress 5.0) and to `gzip -d`.

## Install

```sh
moon add gaato/lzw
```

## Usage

One shot, naming the flavour:

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

Streaming: feed input as it arrives, take output in slices of the size you choose.

```mbt check
///|
fn decode_all(
  format : @lzw.Format,
  chunks : Array[Bytes],
  sink : (BytesView) -> Unit,
) -> Unit raise {
  let decoder = @lzw.Decoder(format)
  let out = FixedArray::make(64 * 1024, b'\x00')
  for i, chunk in chunks {
    let mut input = chunk[:]
    for ;; {
      let status = decoder.step(
        input,
        out.mut_view(),
        end=i == chunks.length() - 1,
      )
      input = input[decoder.last_consumed():]
      sink(Bytes::from_array(out[:decoder.last_produced()]))
      match status {
        Done => return
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
  }
}

///|
test "decode a stream chunk by chunk" {
  let tiff = @lzw.Format::tiff()
  let stream = @lzw.compress(b"a strip of a TIFF image", tiff)
  let decoded = Buffer()
  decode_all(tiff, [stream[:5].to_owned(), stream[5:].to_owned()], bytes => {
    decoded.write_bytes(bytes.to_owned())
  })
  assert_eq(decoded.to_bytes(), b"a strip of a TIFF image")
}
```

`Encoder(format)` streams the other way: `Continue` takes input and `Finish` ends the stream. LZW has no way to flush, so `Flush` raises `Unsupported`, as the byte-stream contract has it for such formats. Both keep the rules of [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), and implement its `Decode` and `Encode`.

## The flavours

| `Format` | Bits packed from | Codes | Widens | Ends |
|---|---|---|---|---|
| `gif(min_code_size)` | least significant | clear `1 << n`, end after it; `n + 1` to 12 bits | when the next code passes a power of two | at the end code |
| `tiff()`, `pdf()` | most significant | clear 256, end 257; 9 to 12 bits | one code early | at the end code |
| `pdf(early_change=false)` | most significant | as TIFF's | as GIF's | at the end code |
| `unix_compress(max_bits~, block_mode~)` | least significant | clear 256 in block mode, no end; 9 to `max_bits` (10 to 16) | as GIF's, each change of width and each clear padding its run of codes to a multiple of eight | with the input |

GIF's LZW is an image's data with its sub-blocks joined, from the minimum code size the byte before them gives (2 to 8, and 1, which some files have; others raise `Unsupported`). .Z begins with its header: an encoder writes `max_bits` and block mode into it, and a decoder takes them from it, refusing a stream wider than its own `max_bits` with `LimitExceeded`, since its table grows with the width. `stream_format()` gives what the header says.

Decoders take what writers leave: a GIF table that fills without a clear (GIF89a allows the clear to come later, and its codes stay 12 bits), and with `Decoder(allow_missing_end=true)` a GIF, TIFF or PDF stream that ends without its end code, as many writers leave it. Without it, such a stream raises `Truncated`. `Decoder(until=EndOfMember)` stops right after the end code, consuming nothing past its byte; .Z, which has no end code, raises `Unsupported` under it.

Not included: .Z of 9 bits, which `Unsupported` refuses both ways: compress 5.0 writes it, but compress and gzip read it back wrongly (they widen to 10 bits once its table fills, and compress's encoder does not), so no stream of it is what both sides agree on. The old TIFF LZW, packed from the least significant bit, that libtiff reads as a compatibility case; GIF's sub-blocks and TIFF's strips, which belong to those formats' readers; and LZW variants of other formats (ZIP's shrink, ARC's).

## Encoding

The encoder writes .Z as compress 5.0 does, the ratio check that clears the table when compression worsens included: on the test data, at 16, 12 and 10 bits, it writes compress's bytes. GIF and TIFF are weezl's bytes until the table fills; then this encoder clears it where giflib does for GIF and for PDF with `early_change=false` (instead of defining code 4095), and libtiff for TIFF and PDF's default (instead of defining code 4093), a little apart from weezl. It begins GIF, TIFF and PDF streams with a clear code, as TIFF requires. `compress_bound(n, format)` is the most it writes for `n` bytes.

## Memory

The decoder holds the table, 7 bytes a code: 28 KiB for GIF, TIFF and PDF, 448 KiB for .Z of 16 bits (`decoder_memory_bound(format)`); the encoder a hash table of twice the codes, 48 KiB and 768 KiB (`encoder_memory_bound(format)`). A string never outgrows the table, so a decoder writes its output into the caller's slices from the table and a string's worth of bytes. `memory_usage()` reports each.

## Errors

A malformed stream raises `CodecError(kind, message)` with `Truncated` (the input ends before the end code, or inside .Z's header), `Corrupt` (a first code that is no literal, a code past the table, a .Z header that is not one), `Unsupported`, `LimitExceeded` or `TrailingData` (bytes after the end code); `max_output` raises `LimitExceeded` past it. The decoders do not abort. A step that raises first hands out the output before the error; after that, steps raise it again until `reset`.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/lzw/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [GIF89a](https://www.w3.org/Graphics/GIF/spec-gif89a.txt), [TIFF 6.0](https://www.itu.int/itudoc/itu-t/com16/tiff-fx/docs/tiff6.pdf) (section 13), [PDF 2.0's LZWDecode](https://pdfa.org/resource/iso-32000-2/), and [ncompress](https://github.com/vapier/ncompress)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md) that `Decoder` and `Encoder` keep
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/lzw/RESOURCE_BOUNDS.md) and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/lzw/TEST_COVERAGE.md)

## License

Apache-2.0.
