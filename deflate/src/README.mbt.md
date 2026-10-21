# gaato/deflate

Streaming decoders for DEFLATE (RFC 1951) and the two formats around it, zlib (RFC 1950) and gzip (RFC 1952), in MoonBit. Native, JS, Wasm and Wasm GC.

```fish
moon add gaato/deflate
```

Three packages, one per format; import those you need in your `moon.pkg`:

| Package | Format | Use it for |
|---|---|---|
| `gaato/deflate` | raw DEFLATE | ZIP entries, WebSocket `permessage-deflate`, formats that frame DEFLATE themselves |
| `gaato/deflate/zlib` | zlib | HTTP's `deflate` coding, PNG, Discord's `zlib-stream` |
| `gaato/deflate/gzip` | gzip | `.gz` files, HTTP's `gzip` coding |

One shot:

```mbt check
///|
test "decompress a whole stream of each format" {
  let raw = b"\xcb\x48\xcd\xc9\xc9\x07\x00"
  assert_eq(@deflate.decompress(raw), b"hello")
  let zlib = b"\x78\x9c\xcb\x48\xcd\xc9\xc9\x07\x00\x06\x2c\x02\x15"
  assert_eq(@zlib.decompress(zlib, max_output=16 * 1024 * 1024), b"hello")
  let gzip = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00"
  assert_eq(@gzip.decompress(gzip), b"hello")
}
```

Streaming: feed input as it arrives, take output in slices of the size you choose. Every step says whether its input is the last: `end=false` before, `end=true` with the last input, so that a stream cut short raises `Truncated` instead of ending quietly. `Status` is [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes)'s, re-exported by each package: match `Done`, `NeedMoreInput` and `NeedMoreOutput` unqualified, or write `@gzip.Status::Done`.

```mbt check
///|
fn gunzip(chunks : Array[Bytes], sink : (BytesView) -> Unit) -> Unit raise {
  let decoder = @gzip.Decoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  for i, chunk in chunks {
    let mut input = chunk[:]
    for ;; {
      let status = decoder.step_into(input, out, end=i == chunks.length() - 1)
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
test "decode a gzip stream chunk by chunk" {
  let decoded = Buffer()
  gunzip(
    [
      b"\x1f\x8b\x08\x00\x00\x00\x00\x00", b"\x02\x03\xcb\x48\xcd\xc9\xc9\x07", b"\x00\x86\xa6\x10\x36\x05\x00\x00\x00",
    ],
    bytes => decoded.write_bytes(bytes.to_owned()),
  )
  assert_eq(decoded.to_bytes(), b"hello")
}
```

Each `Decoder` implements `gaato/codec_bytes`'s `Decode`, so code written against that contract (an HTTP client, a command-line tool) takes any of them as it takes the other decoders of [codecs.mbt](https://github.com/gaato/codecs.mbt).

## gzip

A gzip stream may hold several members, as `cat a.gz b.gz` makes, and nothing marks the last one. By default the decoder reads every member, as the `gzip` command does. After a member, bytes that begin another (`1f 8b`) are read as one; anything else, zero padding included, raises `TrailingData`. A decoder that skipped zeros would also skip the members after them.

`header()` gives the current member's header: the extra field, the name and the comment as the bytes hold them (RFC 1952 writes names in ISO 8859-1; they are not converted), and the time, flags and OS. `until=EndOfMember` stops right after the first member and consumes nothing past it, so that you can decide yourself what may follow:

```mbt check
///|
test "one member, then what follows it" {
  let gz = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00"
  let input = Bytes::from_array([..gz, 0, 0, 0, 0])
  let decoder = @gzip.Decoder(until=EndOfMember)
  let out = FixedArray::make(64, b'\x00')
  assert_true(decoder.step_into(input, out, end=true) is Done)
  assert_eq(Bytes::from_array(out[:decoder.last_produced()]), b"hello")
  assert_eq(input[decoder.last_consumed():], b"\x00\x00\x00\x00")
  let header = decoder.header().unwrap()
  assert_eq(header.os, b'\x03')
  assert_true(header.name is None)
}
```

A header's extra field, name and comment may hold at most `max_header_bytes` between them, 65,536 by default; a header that holds more raises `LimitExceeded({ resource: Memory, .. })`, rather than being kept whole or cut short.

## zlib

A zlib stream that was compressed with a preset dictionary names it by its Adler-32. Without it the decoder raises `DictionaryRequired(Some(id))`, and with another one `DictionaryMismatch`; make a new decoder with the right dictionary and start over. A stream that names no dictionary ignores the one you give.

```mbt check
///|
test "a stream that needs a dictionary" {
  let dictionary = b"hello, dictionary"
  // zlib.deflateSync("hello", { dictionary }) in Node.
  let stream = b"\x78\xbb\x39\x4e\x06\x97\xcb\x00\x09\x00\x00\x06\x2c\x02\x15"
  let needed = try @zlib.decompress(stream) catch {
    @codec.CodecError(DictionaryRequired(id), _) => id
    _ => None
  } noraise {
    _ => None
  }
  assert_eq(needed, Some(961414807)) // the Adler-32 of the dictionary
  assert_eq(@zlib.decompress(stream, dictionary~), b"hello")
}
```

Discord's `zlib-stream` gateway compression is one zlib stream per connection that never ends; each message ends in a sync flush (`00 00 ff ff`). Keep one decoder for the connection and pass each message with `end=false`: when it answers `NeedMoreInput` with the message consumed, everything the message holds has been written.

`@zlib.is_header(cmf, flg)` tells a zlib header from the start of raw DEFLATE, for HTTP's `deflate` coding, which is zlib but which some servers send raw. It is a heuristic, though a strong one.

## What it does

- Decodes every DEFLATE block (stored, fixed and dynamic Huffman codes) with a 32 KiB window, and preset dictionaries for raw DEFLATE and zlib. It refuses what zlib refuses: reserved block types and codes, over-subscribed and incomplete codes, distances before the start of the output, and the reserved header fields and values of zlib and gzip.
- Checks every checksum: zlib's Adler-32, gzip's CRC-32 and length, and the header CRC when a gzip header has one. Output comes out as soon as it is decoded, before the checksum that covers it, so `ChecksumMismatch` can follow output you already have; `decompress` returns only checked output.
- Never reads past the end of a stream: after `Done` under `until=EndOfMember`, what follows is `input[last_consumed():]`, whatever the input splits. Raw DEFLATE and zlib streams cannot be concatenated, so under the default `until=EndOfInput` anything after one raises `TrailingData`.
- Takes input in chunks of any size, down to one byte, and writes output into buffers of any size, under the rules of `gaato/codec_bytes`. Memory is the window and the decoding tables, about 72 KiB, plus a dictionary's last 32 KiB (twice for zlib, which keeps a copy for the streams that name it) and a gzip header's fields; `memory_usage()` reports it.
- Every malformed stream raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s `CodecError(kind, message)`, with the kind `Truncated`, `Corrupt`, `ChecksumMismatch`, `TrailingData`, `DictionaryRequired`, `DictionaryMismatch` or `LimitExceeded` (a gzip header over `max_header_bytes`, with `resource: Memory`; more than `max_output` from `decompress`, with `resource: Output`). An error inside the DEFLATE data of a zlib or gzip stream keeps its kind. It does not abort. To match on the error, add `gaato/codec` to your package's imports.

Not included: an encoder.

## Known limits

- The DEFLATE data is decoded by [moonbit-community/flate](https://mooncakes.io/docs/moonbit-community/flate)'s inflater, which none of the packages' signatures name.
- Two kinds of malformed DEFLATE are refused with another kind of error than zlib's. A dynamic block whose code has no end-of-block code is refused as `Truncated` when the input runs out, after the block's literals have come out, where zlib refuses its header as `Corrupt`. A dynamic block whose code-length code is empty is refused as `Corrupt` at once, where zlib asks for more input first. Both refuse; no valid stream decodes differently.

## License

Apache-2.0.
