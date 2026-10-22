# gaato/deflate

Streaming decoders and encoders for DEFLATE (RFC 1951) and the two formats around it, zlib (RFC 1950) and gzip (RFC 1952), in pure MoonBit, for Native, JS, Wasm and Wasm GC. They take input in chunks of any size, write output into slices of any size, verify every checksum, and keep their memory fixed, so they fit HTTP's `gzip` and `deflate` codings, `.gz` files, PNG and WebSocket compression alike.

## Install

```sh
moon add gaato/deflate
```

## Usage

Each format is its own package; import those you need in your `moon.pkg` (see [Packages](#packages)).

One shot:

```mbt check
///|
test "compress and decompress a whole stream of each format" {
  let text = b"hello, hello, hello"
  assert_eq(@deflate.decompress(@deflate.compress(text)), text)
  assert_eq(@zlib.decompress(@zlib.compress(text, level=9)), text)
  assert_eq(@gzip.decompress(@gzip.compress(text, level=1)), text)
}

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

Encoding works the same way, with an action instead of `end`: `Continue` takes input, `Flush` makes the output so far decode to the input so far while the stream goes on, and `Finish` ends the stream. `EncodeAction` is re-exported too.

```mbt check
///|
/// Compresses each message of a connection into one zlib stream, as
/// Discord's `zlib-stream` does: every message ends in a sync flush. Returns
/// the bytes to send for each message.
fn compress_messages(messages : Array[Bytes]) -> Array[Bytes] {
  let encoder = @zlib.Encoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  messages.map(message => {
    let part = Buffer()
    let mut input = message[:]
    for ;; {
      let status = encoder.step_into(input, out, action=Flush)
      input = input[encoder.last_consumed():]
      part.write_bytes(Bytes::from_array(out[:encoder.last_produced()]))
      if status is NeedMoreInput {
        break
      }
    }
    part.to_bytes()
  })
}

///|
test "each message decodes on its own, without the end of the stream" {
  let messages = [b"{\"op\":10}", b"{\"op\":11}"]
  let decoder = @zlib.Decoder()
  let out = FixedArray::make(64 * 1024, b'\x00')
  for i, part in compress_messages(messages) {
    assert_true(part[part.length() - 4:] is [0x00, 0x00, 0xff, 0xff])
    assert_true(decoder.step_into(part, out, end=false) is NeedMoreInput)
    assert_eq(Bytes::from_array(out[:decoder.last_produced()]), messages[i])
  }
}
```

`level` goes from 0 to 9, as zlib's and the `gzip` command's do: 0 stores the input in stored blocks, 1 is the fastest, 9 the smallest, and 6, the default, a balance; levels outside are clamped. `Flush` is zlib's sync flush (`Z_SYNC_FLUSH`): it ends with an empty stored block, `00 00 ff ff`, and a flush with nothing new since the last adds nothing. A flush ends the current block and costs at least the 5 bytes of the empty one, so flush where a reader needs the data, not after every write; matches still reach back across it. The output does not depend on how the input and the output are split, only on the input, the options and where the flushes fall. The levels follow libdeflate's; how they compare with zlib's is in [Compression levels and ratio](https://github.com/gaato/codecs.mbt/blob/main/deflate/docs/compression.md). An encoder never raises.

Each `Decoder` implements `gaato/codec_bytes`'s `Decode`, and each `Encoder` its `Encode`, so code written against that contract (an HTTP client, a command-line tool) takes any of them as it takes the other codecs of [codecs.mbt](https://github.com/gaato/codecs.mbt).

## Packages

| Package | Format | Use it for |
|---|---|---|
| `gaato/deflate` | raw DEFLATE | ZIP entries, WebSocket `permessage-deflate`, formats that frame DEFLATE themselves |
| `gaato/deflate/zlib` | zlib | HTTP's `deflate` coding, PNG, Discord's `zlib-stream` |
| `gaato/deflate/gzip` | gzip | `.gz` files, HTTP's `gzip` coding |

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

A decoder that has no use for them, as an HTTP client usually has none, passes `keep_header=false`: it skips the extra field, the name and the comment whatever their size, holds none of their bytes, and still checks the header CRC. `header()` then gives the time, flags and OS, with the other fields None, and `max_header_bytes` does not apply. `@gzip.decompress` skips them this way, so a large header never stops it.

```mbt check
///|
test "skip the header's fields" {
  // A member named "a.txt" (FNAME).
  let gz = b"\x1f\x8b\x08\x08\x00\x00\x00\x00\x00\x03a.txt\x00\xcb\x48\xcd\xc9\xc9\x07\x00\x86\xa6\x10\x36\x05\x00\x00\x00"
  let decoder = @gzip.Decoder(keep_header=false)
  let out = FixedArray::make(64, b'\x00')
  assert_true(decoder.step_into(gz, out, end=true) is Done)
  assert_eq(Bytes::from_array(out[:decoder.last_produced()]), b"hello")
  assert_true(decoder.header() is Some({ name: None, os: b'\x03', .. }))
  assert_eq(@gzip.decompress(gz), b"hello")
}
```

`@gzip.Encoder` and `@gzip.compress` write one member. Without a `header`, it has no name, comment or extra field, MTIME 0 and OS 255 (both unknown), so that the same input gives the same bytes on every target and every day, and XFL as zlib sets it: 4 at levels 0 and 1, 2 at level 9, 0 otherwise. A `Header` you give is written as it is, but it must be writable (`Header::is_writable`): an extra field of at most 65,535 bytes, and no zero byte in the name or the comment, which a zero ends. Passing one that is not is a programming error, and aborts.

```mbt check
///|
test "a member with a name" {
  let header : @gzip.Header = {
    text: true,
    mtime: 1700000000,
    xfl: b'\x00',
    os: b'\x03',
    extra: None,
    name: Some(b"notes.txt"),
    comment: None,
  }
  assert_true(header.is_writable())
  let gz = @gzip.compress(b"hello", header~)
  let decoder = @gzip.Decoder()
  let out = FixedArray::make(64, b'\x00')
  assert_true(decoder.step_into(gz, out, end=true) is Done)
  assert_eq(decoder.header(), Some(header))
  // The default header: MTIME 0, XFL 0 at level 6, OS 255.
  assert_eq(
    @gzip.compress(b"hello")[:10],
    b"\x1f\x8b\x08\x00\x00\x00\x00\x00\x00\xff",
  )
}
```

## zlib

A zlib stream that was compressed with a preset dictionary names it by its Adler-32, which `@zlib.dictionary_id` computes. Without it the decoder raises `DictionaryRequired(Some(id))`, and with another one `DictionaryMismatch`; make a new decoder with the right dictionary and start over. A stream that names no dictionary ignores the one you give. A decoder keeps a view of the dictionary's last 32 KiB, not a copy, so the `Bytes` it is a view of stay alive as long as the decoder; the same goes for `@deflate.Decoder(dictionary=...)`.

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

An encoder given a `dictionary` names it in the header, and its stream's matches may reach back into it; the same goes for `@deflate.Encoder(dictionary=...)`, whose stream does not name it. Its header's FLEVEL says which kind of level made it, as zlib's does, so `@zlib.compress` writes the same header bytes as zlib: `78 9c` at the default level.

```mbt check
///|
test "compress with a dictionary" {
  let dictionary = b"{\"op\":0,\"t\":\"MESSAGE_CREATE\",\"d\":{\"content\":\""
  let message = b"{\"op\":0,\"t\":\"MESSAGE_CREATE\",\"d\":{\"content\":\"hi\"}}"
  let stream = @zlib.compress(message, dictionary~)
  assert_eq(@zlib.decompress(stream, dictionary~), message)
  assert_true(stream.length() < @zlib.compress(message).length())
}
```

`@zlib.is_header(cmf, flg)` tells a zlib header from the start of raw DEFLATE, for HTTP's `deflate` coding, which is zlib but which some servers send raw. It is a heuristic, though a strong one.
## Streams that do not end

Discord's `zlib-stream` gateway compression is one zlib stream per connection that never ends; each message ends in a sync flush (`00 00 ff ff`), and a message may come in several WebSocket frames. Keep one decoder for the connection, made with `until=EndOfMember`, and pass every frame with `end=false`, since no frame is the last:

- `NeedMoreInput`, with the frame consumed, is the answer to every frame. Everything the frame determines has been written, so after a frame that ends in `00 00 ff ff` the whole message is out. The decoder does not know where messages end; the suffix does.
- `NeedMoreOutput`: the slice is full. Call again with the rest of the frame, `frame[last_consumed():]`.
- `Done`: the stream ended, which a gateway stream never does. `until=EndOfMember` makes the decoder report this at once; under the default, it would wait for what follows and raise `TrailingData` on the next frame.

When the connection closes, drop the decoder or `reset` it for the next one, rather than passing `end=true`, which raises `Truncated`: the stream was cut, not ended. However long the connection, the decoder holds its window and tables, never the messages so far.

```mbt check
///|
/// Inflates the frames of one connection, and returns its messages.
fn inflate_messages(frames : Array[Bytes]) -> Array[Bytes] raise {
  let decoder = @zlib.Decoder(until=EndOfMember)
  let out = FixedArray::make(64 * 1024, b'\x00')
  let message = Buffer()
  let messages = []
  for frame in frames {
    let mut input = frame[:]
    for ;; {
      let status = decoder.step_into(input, out, end=false)
      input = input[decoder.last_consumed():]
      message.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
      match status {
        NeedMoreInput => break
        NeedMoreOutput => ()
        Done => fail("the stream ended")
      }
    }
    if frame is [.., 0x00, 0x00, 0xff, 0xff] {
      messages.push(message.to_bytes())
      message.reset()
    }
  }
  messages
}

///|
test "a message split across frames comes out once its flush arrives" {
  let messages = [b"{\"op\":10}", b"{\"op\":0,\"t\":\"READY\"}"]
  let parts = compress_messages(messages)
  // The second message in two frames.
  let second = parts[1]
  let frames = [parts[0], second[:3].to_owned(), second[3:].to_owned()]
  assert_eq(inflate_messages(frames), messages)
}
```

## Limits

- A decoder's memory is the 32 KiB window and its decoding tables, about 46 KiB from its first step to its last, with a dictionary or without (a dictionary is your bytes, held by reference), plus a gzip header's fields up to `max_header_bytes`.
- An encoder's memory is fixed by its level: about 530 KiB at the default level, less at levels 0 and 1, and for gzip its header's bytes.
- `memory_usage()` reports both; [RESOURCE_BOUNDS.md](https://github.com/gaato/codecs.mbt/blob/main/deflate/RESOURCE_BOUNDS.md) gives every bound exactly.
- Levels stop at 9: libdeflate's levels 10 to 12, near-optimal parsing at several times the time, are not here, and higher levels are clamped to 9.
- A flush is a sync flush: zlib's full flush, which also forgets the window, is not offered.

## Errors

A decoder refuses what zlib refuses, with zlib's kind of error: reserved block types and codes, over-subscribed and incomplete codes, distances before the start of the output, and the reserved header fields and values of zlib and gzip. Every malformed stream raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s `CodecError(kind, message)`; a decoder does not abort. The kinds:

- `Truncated`: the input ends inside a stream.
- `Corrupt`: the input is not a valid stream.
- `ChecksumMismatch`: a checksum or a gzip length does not match.
- `TrailingData`: bytes after the stream (after a gzip member, bytes that start no other member).
- `DictionaryRequired`, `DictionaryMismatch`: a zlib stream names a preset dictionary that was not given, or another one was.
- `LimitExceeded`: a gzip header over `max_header_bytes`, with `resource: Memory`; more than `max_output` from `decompress`, with `resource: Output`.

An error inside the DEFLATE data of a zlib or gzip stream keeps its kind. In a `catch` on these functions, `CodecError(kind, _)` and the kinds match unqualified, with no import; to name the types elsewhere, import [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), which re-exports them.

Every checksum is checked: zlib's Adler-32, gzip's CRC-32 and length, and the header CRC when a gzip header has one. Output comes out as soon as it is decoded, before the checksum that covers it, so `ChecksumMismatch` can follow output you already have; `decompress` returns only checked output.

A decoder never reads past the end of a stream: after `Done` under `until=EndOfMember`, what follows is `input[last_consumed():]`, whatever the input splits. Raw DEFLATE and zlib streams cannot be concatenated, so under the default `until=EndOfInput` anything after one raises `TrailingData`.

A step that raises first writes the output that comes before the error, and `last_consumed()` and `last_produced()` say what it took and wrote, so a stream with bytes after it gives all its output, then `TrailingData`, with `last_consumed()` at its end, whether it came in one step or many. A malformed stream gives the same output before the same kind of error however its input and output are split.

The header checks, the decoder's verdict on a code's lengths and the canonical codes the encoder writes are proved against RFC 1950, 1951 and 1952; [PROOFS.md](https://github.com/gaato/codecs.mbt/blob/main/deflate/PROOFS.md) lists what is proved and what is trusted.

## Links

- [Changelog](https://github.com/gaato/codecs.mbt/blob/main/deflate/CHANGELOG.md)
- [Repository](https://github.com/gaato/codecs.mbt)
- [The byte-stream codec contract](https://github.com/gaato/codecs.mbt/blob/main/CONTRACT.md) that every `Decoder` and `Encoder` keeps
- [Compression levels and ratio](https://github.com/gaato/codecs.mbt/blob/main/deflate/docs/compression.md): how the levels work, and sizes against zlib
- [Resource bounds](https://github.com/gaato/codecs.mbt/blob/main/deflate/RESOURCE_BOUNDS.md): every limit and the tests that hold it
- [Proofs](https://github.com/gaato/codecs.mbt/blob/main/deflate/PROOFS.md) and [test coverage](https://github.com/gaato/codecs.mbt/blob/main/deflate/TEST_COVERAGE.md)

## License

Apache-2.0.
