# gaato/deflate

DEFLATE (RFC 1951), zlib (RFC 1950) and gzip (RFC 1952) for MoonBit:
one-shot and streaming decoders and encoders, and a decoder for Deflate64
(ZIP method 9). Pure MoonBit, on Native, JS, Wasm and Wasm GC.

- **Streaming in fixed memory.** Decoders and encoders take input in pieces
  of any size, down to one byte, and write into output buffers you supply.
  Their memory is fixed when they are made, about 46 KiB for a DEFLATE
  decoder, however long the stream.
- **Checked.** Every checksum is verified: zlib's Adler-32, gzip's CRC-32 and
  length, and a gzip header's CRC. Malformed input raises an error and never
  aborts. The raw, zlib and gzip decoders are tested against zlib on crafted
  and corrupted streams: they refuse what zlib refuses, with the same kind of
  error.
- **Encoders** with levels 0 to 12, sync flush, preset dictionaries and a
  window from 256 bytes to 32 KiB.
- **gzip** headers read and written, and files of several members.
- **One step API and one error type** with the other codecs of
  [codecs.mbt](https://github.com/gaato/codecs.mbt): every `Decoder` and
  `Encoder` implements the traits of
  [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes).

## Install

```sh
moon add gaato/deflate
```

Each format is its own package. Import the ones you need in your package's
`moon.pkg` and call them by their last name: `@deflate`, `@zlib`, `@gzip`,
`@deflate64`.

| Package | Format | Use it for |
| --- | --- | --- |
| `gaato/deflate` | raw DEFLATE | ZIP method 8, WebSocket `permessage-deflate`, formats that frame DEFLATE themselves |
| `gaato/deflate/zlib` | zlib | HTTP's `deflate` coding, PNG image data, Discord's `zlib-stream` |
| `gaato/deflate/gzip` | gzip | `.gz` files, HTTP's `gzip` coding |
| `gaato/deflate/deflate64` | Deflate64, decode only | ZIP method 9 entries |

## Whole buffers

```mbt check
///|
test "compress and decompress a whole stream of each format" {
  let text = b"hello, hello, hello"
  assert_eq(@deflate.decompress(@deflate.compress(text)), text)
  assert_eq(@zlib.decompress(@zlib.compress(text, level=9)), text)
  assert_eq(@gzip.decompress(@gzip.compress(text, level=1)), text)
}

///|
test "decompress with a cap on the output" {
  let gzip = b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\x03\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00"
  assert_eq(@gzip.decompress(gzip, max_output=16 * 1024 * 1024), b"hello")
}
```

`decompress` has no cap unless you pass `max_output`; past it, it raises
`LimitExceeded` with `resource: Output`. Set one for input you did not make.
`decompress` returns only output its checksums have verified.

## Decode as the input arrives

Keep one decoder for the stream. Each `step_into` takes the input you have
and a buffer to write into: advance the input by `last_consumed()`, take
`last_produced()` bytes of output, and call again on `NeedMoreOutput`. Pass
`end=true` with the last input, an empty one if the source has just run dry,
so that a stream cut short raises `Truncated` instead of ending quietly.

```mbt check
///|
/// Decodes a gzip stream that `read` hands over in pieces, `None` once it has
/// no more, and passes the output to `write` as it is decoded.
fn gunzip(read : () -> Bytes?, write : (Bytes) -> Unit) -> Unit raise {
  let decoder = @gzip.Decoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  for ;; {
    let piece = read()
    let end = piece is None
    let mut input = match piece {
      Some(bytes) => bytes[:]
      None => b""[:]
    }
    for ;; {
      let status = decoder.step_into(input, out, end~)
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
test "decode a gzip stream that arrives in pieces" {
  let pieces = [
    b"\x1f\x8b\x08\x00\x00\x00\x00\x00", b"\x02\x03\xcb\x48\xcd\xc9\xc9\x07", b"\x00\x86\xa6\x10\x36\x05\x00\x00\x00",
  ]
  let mut next = 0
  let decoded = Buffer()
  gunzip(
    () => if next < pieces.length() {
      next += 1
      Some(pieces[next - 1])
    } else {
      None
    },
    bytes => decoded.write_bytes(bytes),
  )
  assert_eq(decoded.to_bytes(), b"hello")
  // A source with nothing in it is a stream cut short, not an empty one.
  let empty = try gunzip(() => None, _ => ()) catch {
    @codec_bytes.CodecError::CodecError(kind, _) => Some(kind)
    _ => None
  } noraise {
    _ => None
  }
  assert_true(empty is Some(Truncated))
}
```

`step` does the same into a `MutArrayView[Byte]`; `step_into` takes a whole
`FixedArray` and copies in bulk. Output may come before the checksum that
covers it, so `ChecksumMismatch` can follow output you already have. Every
decoder also has `is_finished()`, `memory_usage()` and `reset()`, which
starts a new stream with the same options and reuses what the decoder
allocated.

## Encode as the input arrives

An encoder's step takes an action instead of `end`. `Continue` takes input,
`Flush` makes the output so far decode to the input so far while the stream
goes on, and `Finish` ends the stream. Keep stepping while the answer is
`NeedMoreOutput`, passing what was not taken again with the same action.
An encoder never raises.

```mbt check
///|
/// Steps `encoder` over `input` with `action`, passing each piece of output
/// to `write`, until all of `input` is taken and, for `Finish`, the stream
/// has ended.
fn encode(
  encoder : @zlib.Encoder,
  input : BytesView,
  action : @zlib.EncodeAction,
  out : FixedArray[Byte],
  write : (Bytes) -> Unit,
) -> Unit {
  let mut input = input
  for ;; {
    let status = encoder.step_into(input, out, action~)
    input = input[encoder.last_consumed():]
    write(Bytes::from_array(out[:encoder.last_produced()]))
    if status is (NeedMoreInput | Done) {
      break
    }
  }
}

///|
test "flush after each message, then finish the stream" {
  let encoder = @zlib.Encoder()
  let decoder = @zlib.Decoder(until=EndOfMember)
  let out = FixedArray::make(64 * 1024, b'\x00')
  let decoded = FixedArray::make(64 * 1024, b'\x00')
  let stream = Buffer()
  for message in [b"{\"op\":10}", b"{\"op\":11}"] {
    let part = Buffer()
    encode(encoder, message, Flush, out, bytes => part.write_bytes(bytes))
    let part = part.to_bytes()
    // A flushed part ends in 00 00 ff ff, and decodes in full on arrival.
    assert_true(part is [.., 0x00, 0x00, 0xff, 0xff])
    assert_true(decoder.step_into(part, decoded, end=false) is NeedMoreInput)
    assert_eq(Bytes::from_array(decoded[:decoder.last_produced()]), message)
    stream.write_bytes(part)
  }
  encode(encoder, b"", Finish, out, bytes => stream.write_bytes(bytes))
  assert_eq(@zlib.decompress(stream.to_bytes()), b"{\"op\":10}{\"op\":11}")
}
```

`Flush` is zlib's sync flush (`Z_SYNC_FLUSH`) and costs at least 5 bytes, so
flush where a reader needs the data. Matches still reach back across it;
zlib's full flush, which forgets the window, is not offered. The output
depends only on the input, the options and where the flushes fall, never on
how the input or the output is split. Every encoder also has
`is_finished()`, `memory_usage()` and `reset()`.

## Options

| Option | Taken by | Default | Meaning |
| --- | --- | --- | --- |
| `level` | `compress`, `Encoder` | 6 | 0 stores, 1 is the fastest, 12 the smallest. -1, zlib's `Z_DEFAULT_COMPRESSION`, means 6; other values outside 0 to 12 are clamped. The levels follow libdeflate's: 10 to 12 search much harder and hold far more memory. |
| `window_bits` | raw and zlib `compress`, `Encoder` | 15 (32 KiB) | 8 to 15, clamped. No match reaches further back than `1 << window_bits` bytes, for a peer that keeps less history, as WebSocket's `server_max_window_bits` and `client_max_window_bits` negotiate. A zlib header's CINFO says it. |
| `dictionary` | raw and zlib `compress`, `decompress`, `Encoder`, `Decoder` | none | A preset dictionary; see [zlib](#zlib). |
| `max_output` | every `decompress` | none | A cap on the decoded size; a negative one counts as 0. |
| `until` | every `Decoder` | `EndOfInput` | `EndOfMember` stops right after the first stream or gzip member and consumes nothing past it. |
| `keep_header` | `@gzip.Decoder` | `true` | `false` skips each header's extra field, name and comment, whatever their size; see [gzip](#gzip). |
| `max_header_bytes` | `@gzip.Decoder` | 65,536 | The most a header's extra field, name and comment may hold between them. |
| `header` | `@gzip.compress`, `@gzip.Encoder` | none | The member's header; see [gzip](#gzip). |

## Memory and sizes

| | Holds |
| --- | --- |
| Raw or zlib decoder | 46,592 bytes, from its first step to its last |
| gzip decoder | the same, plus the current header's fields up to `max_header_bytes` (none with `keep_header=false`) |
| Deflate64 decoder | 79,384 bytes |
| Encoder, levels 5 to 9 | 542,516 bytes; less at lower levels |
| Encoder, levels 10 to 12 | up to 7,056,748 bytes |

`decoder_memory_bound()` and `encoder_memory_bound(level~)` give these before
you make one; `memory_usage()` reports what one holds. A preset dictionary is
your bytes, kept by reference and not counted. `compress_bound(n)` is the
most `compress` writes for `n` bytes, at any level; a streaming encoder stays
within it plus 10 bytes per `Flush`. A decoder bounds its memory, not its
output: when streaming, count bytes at your sink to cap the total.

## gzip

A gzip file may hold several members, as `cat a.gz b.gz` makes. By default
the decoder reads every member, as the `gzip` command does; bytes after a
member that do not begin another, zero padding included, raise
`TrailingData`. `until=EndOfMember` stops right after the first member, so
that you decide what may follow it.

`header()` gives the current member's header, with the name and comment as
the bytes hold them (ISO 8859-1, not converted). `keep_header=false` skips
those fields at any size and still checks the header CRC;
`@gzip.decompress` does this.

`@gzip.compress` and `@gzip.Encoder` write one member. Without a `header`,
it has MTIME 0 and OS 255, so the same input gives the same bytes on every
target and every day. A `Header` you give must pass `Header::is_writable`
(an extra field of at most 65,535 bytes, no zero byte in the name or the
comment); one that does not aborts.

## zlib

A zlib stream compressed with a preset dictionary names it by its Adler-32,
which `@zlib.dictionary_id` computes. Without the dictionary the decoder
raises `DictionaryRequired(Some(id))`, and with another one
`DictionaryMismatch`; make a new decoder with the right one and start over.
A stream that names no dictionary ignores the one you give.

```mbt check
///|
test "a stream that needs a dictionary" {
  let dictionary = b"hello, dictionary"
  // zlib.deflateSync("hello", { dictionary }) in Node.
  let stream = b"\x78\xbb\x39\x4e\x06\x97\xcb\x00\x09\x00\x00\x06\x2c\x02\x15"
  let needed = try @zlib.decompress(stream) catch {
    CodecError(DictionaryRequired(id), _) => id
    _ => None
  } noraise {
    _ => None
  }
  assert_eq(needed, Some(@zlib.dictionary_id(dictionary)))
  assert_eq(@zlib.decompress(stream, dictionary~), b"hello")
}
```

An encoder given a `dictionary` names it in the header, and its matches may
reach back into it. The raw `@deflate` encoder and decoder take a dictionary
too, which the stream does not name. The header's FLEVEL says which kind of
level made the stream, as zlib's does, so `@zlib.compress` starts with
`78 9c` at the default level.

`@zlib.is_header(cmf, flg)` tells a zlib header from the start of raw
DEFLATE, for servers that send HTTP's `deflate` coding without the zlib
wrapper. It is a strong heuristic, not a proof.

## Streams that never end

A connection that carries one stream flushed after each message, as
Discord's `zlib-stream` does, keeps one `@zlib.Decoder(until=EndOfMember)`
and passes every frame with `end=false`. Each frame answers `NeedMoreInput`
once everything it determines is written, so a frame ending in
`00 00 ff ff` has given its whole message. When the connection closes, drop
or `reset()` the decoder rather than pass `end=true`, which raises
`Truncated`. However long the connection, the decoder holds its window and
tables, never the messages so far.

For WebSocket's `permessage-deflate` (RFC 7692), decode each message with an
`@deflate.Decoder(until=EndOfMember)`, then the appended `00 00 ff ff` as a
step of its own, and accept the message only when
`at_block_boundary()` is then true. Its doc comment says why; `reset` with
`dictionary=` carries the window between messages or, with `b""`, drops it.

## Deflate64

`gaato/deflate/deflate64` decodes ZIP method 9 (Enhanced Deflating), as
7-Zip writes it. Use it explicitly: the ordinary decoder keeps RFC 1951's
codes, under which a Deflate64 entry is refused or decodes wrongly. It has
no encoder and no preset dictionary, and it does not parse ZIP headers: give
it an entry's compressed bytes, and check the entry's size and CRC in your
ZIP reader. For whole ZIP archives, see
[`gaato/zip`](https://mooncakes.io/docs/gaato/zip).

```mbt check
///|
test "decode a Deflate64 entry with a match longer than DEFLATE allows" {
  let entry = b"\x4b\x1c\xfd\xff\x07\x00"
  assert_eq(
    @deflate64.decompress(entry, max_output=1 << 20),
    Bytes::make(65539, b'a'),
  )
}
```

`@deflate64.Decoder(until?)` steps as the other decoders do.

## Errors

Every malformed stream raises
[`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s
`CodecError(kind, message)`. In a `catch` on these functions, `CodecError`
and the kinds match unqualified, with no import; to name the types
elsewhere, import `gaato/codec_bytes`, which re-exports them.

| Kind | When |
| --- | --- |
| `Truncated` | The input ends inside a stream, or holds none. |
| `Corrupt` | The input is not a valid stream: reserved block types or header values, bad Huffman codes, a distance before the start of the output. |
| `ChecksumMismatch` | An Adler-32, a CRC-32, a gzip length or a gzip header CRC does not match. |
| `TrailingData` | Bytes follow the stream; for gzip, bytes that begin no other member. |
| `DictionaryRequired(Some(id))`, `DictionaryMismatch` | A zlib stream names a preset dictionary that was not given, or another one was. |
| `LimitExceeded` | Output past `max_output` (`resource: Output`), or a gzip header's fields past `max_header_bytes` (`resource: Memory`). |

Errors stick: every later step raises the same kind until `reset()`. A step
that raises first writes the output that comes before the error, and
`last_consumed()` and `last_produced()` say what it took and wrote. The
output and the kind of error do not depend on how the input and the output
are split.

## Compared with MoonBit's core library

MoonBit's core library has DEFLATE, zlib and gzip in
`moonbitlang/core/compress`, with no dependency to add. If it does what you
need, it is the simpler choice. The one-shot functions here have the same
shape, so decoding code mostly moves by changing the import. Choose this
module when you need any of these:

- the same step API and error type as the other codecs of codecs.mbt;
- bytes after a gzip stream refused as `TrailingData`, as zlib refuses them;
- gzip headers read and written, `window_bits`, `at_block_boundary()`,
  memory bounds before decoding or encoding, or Deflate64.

[Moving from MoonBit's core library](https://github.com/gaato/codecs.mbt/blob/main/deflate/docs/migrating.md)
lists the names, levels, errors and defaults that differ.

## Links

- [Comparison with other MoonBit implementations](https://github.com/gaato/codecs.mbt/blob/main/bench/README.md#compression-codecs-against-other-implementations):
  features, conformance and speed
- [Compression levels and ratio](https://github.com/gaato/codecs.mbt/blob/main/deflate/docs/compression.md):
  how the levels work, and sizes against zlib
- [Deflate64](https://github.com/gaato/codecs.mbt/blob/main/deflate/docs/deflate64.md):
  format differences and interoperability checks
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/deflate/RESOURCE_BOUNDS.md):
  every limit and the tests that hold it
- [Proofs](https://github.com/gaato/codecs.mbt/blob/main/deflate/PROOFS.md):
  the header checks and Huffman code checks proved against the RFCs, and
  what is trusted
- [Test coverage](https://github.com/gaato/codecs.mbt/blob/main/deflate/TEST_COVERAGE.md)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md)
  that every `Decoder` and `Encoder` keeps
- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/deflate/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)

## License

Apache-2.0.
