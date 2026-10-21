# gaato/deflate

Streaming decoders and encoders for DEFLATE (RFC 1951) and the two formats around it, zlib (RFC 1950) and gzip (RFC 1952), in MoonBit. Native, JS, Wasm and Wasm GC.

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

`level` goes from 0 to 9, as zlib's and the `gzip` command's do: 0 stores the input in stored blocks, 1 is the fastest, 9 the smallest, and 6, the default, a balance; levels outside are clamped. `Flush` is zlib's sync flush (`Z_SYNC_FLUSH`): it ends with an empty stored block, `00 00 ff ff`, and a flush with nothing new since the last adds nothing. A flush ends the current block and costs at least the 5 bytes of the empty one, so flush where a reader needs the data, not after every write; matches still reach back across it. The output does not depend on how the input and the output are split, only on the input, the options and where the flushes fall.

Each `Decoder` implements `gaato/codec_bytes`'s `Decode`, and each `Encoder` its `Encode`, so code written against that contract (an HTTP client, a command-line tool) takes any of them as it takes the other codecs of [codecs.mbt](https://github.com/gaato/codecs.mbt).

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

### A stream that does not end

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

## What it does

- Decodes every DEFLATE block (stored, fixed and dynamic Huffman codes) with a 32 KiB window, and preset dictionaries for raw DEFLATE and zlib. It refuses what zlib refuses, with zlib's kind of error: reserved block types and codes, over-subscribed and incomplete codes, distances before the start of the output, and the reserved header fields and values of zlib and gzip. Crafted streams and thousands of corrupted ones are checked against zlib's answers.
- Checks every checksum: zlib's Adler-32, gzip's CRC-32 and length, and the header CRC when a gzip header has one. Output comes out as soon as it is decoded, before the checksum that covers it, so `ChecksumMismatch` can follow output you already have; `decompress` returns only checked output.
- Never reads past the end of a stream: after `Done` under `until=EndOfMember`, what follows is `input[last_consumed():]`, whatever the input splits. Raw DEFLATE and zlib streams cannot be concatenated, so under the default `until=EndOfInput` anything after one raises `TrailingData`.
- Takes input in chunks of any size, down to one byte, and writes output into buffers of any size, under the rules of `gaato/codec_bytes`. Memory is the window and the decoding tables, 46,592 bytes with a dictionary or without (a dictionary is your bytes, held by reference), plus a gzip header's fields; `memory_usage()` reports it.
- A step that raises first writes the output that comes before the error, and `last_consumed()` and `last_produced()` say what it took and wrote, so a stream with bytes after it gives all its output, then `TrailingData`, with `last_consumed()` at its end: whether it came in one step or many. A malformed stream gives the same output before the same kind of error however its input and output are split.
- Every malformed stream raises [`gaato/codec`](https://mooncakes.io/docs/gaato/codec)'s `CodecError(kind, message)`, with the kind `Truncated`, `Corrupt`, `ChecksumMismatch`, `TrailingData`, `DictionaryRequired`, `DictionaryMismatch` or `LimitExceeded` (a gzip header over `max_header_bytes`, with `resource: Memory`; more than `max_output` from `decompress`, with `resource: Output`). An error inside the DEFLATE data of a zlib or gzip stream keeps its kind. It does not abort. In a `catch` on these functions, `CodecError(kind, _)` and the kinds match unqualified, with no import; to name the types elsewhere, import [`gaato/codec_bytes`](https://mooncakes.io/docs/gaato/codec_bytes), which re-exports them.
- Encodes with libdeflate's levels: 0 stores the input; 1 finds matches in a hash table; 2 to 4 take the longest match at each position, and 5 to 9 look one or two positions ahead for a better one, over hash chains. Each block takes the fixed Huffman code, a dynamic one or no code (stored), whichever is smallest, and ends where the data changes (libdeflate's block splitting) or after 64 KiB. Inputs of a few dozen bytes or less are stored, as libdeflate stores them. With the same input, no dictionary and no flush, the streams are the bytes that libdeflate 1.24 writes when its blocks are limited to 64 KiB. They decode with zlib and the `gzip` command, whole and cut after every flush (`scripts/crosscheck.mbtx`, run in CI), and the same input gives the same bytes on every target, however it is split. An encoder never raises.
- An encoder's memory is fixed by its level: 542,516 bytes at the default level (the 32 KiB window, a 64 KiB block and what the parser looks ahead, the block's output, the match tables and the block's sequences), 361,948 at level 1 and 131,077 at level 0, with a dictionary or without, and for gzip its header's bytes; `memory_usage()` reports it.
- The zlib and gzip header checks, Adler-32's sums (which never overflow), the decoder's verdict on a code's lengths, and the canonical codes the encoder writes are proved against RFC 1950, RFC 1951 and RFC 1952 with `moon prove`; [PROOFS.md](PROOFS.md) lists what is proved and what is trusted.

### Compression ratio

Sizes in bytes of raw DEFLATE streams for six files of the [Silesia corpus](https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia), against zlib 1.3.2.1 at the same levels:

| File | Size | here -1 | zlib -1 | here -6 | zlib -6 | here -9 | zlib -9 |
|---|---:|---:|---:|---:|---:|---:|---:|
| dickens | 10,192,446 | 4,217,525 | 4,585,612 | 3,864,185 | 3,871,628 | 3,816,762 | 3,854,729 |
| mozilla | 51,220,480 | 20,192,961 | 20,577,220 | 18,807,653 | 19,089,118 | 18,716,681 | 19,044,390 |
| nci | 33,553,445 | 3,837,577 | 4,624,591 | 3,102,963 | 3,200,182 | 2,935,668 | 2,987,995 |
| ooffice | 6,152,192 | 3,275,124 | 3,290,526 | 3,073,999 | 3,097,288 | 3,068,726 | 3,092,920 |
| samba | 21,606,400 | 5,866,517 | 6,329,449 | 5,338,862 | 5,451,399 | 5,272,299 | 5,402,704 |
| xml | 5,345,280 | 887,708 | 965,242 | 686,486 | 687,991 | 651,148 | 658,899 |
| total | 128,070,243 | 38,277,412 | 40,372,640 | 34,874,148 | 35,397,606 | 34,461,284 | 35,041,637 |

Level 1 compresses about 5 % more than zlib's level 1, and levels 6 and 9 about 1.5 % more than zlib's: every file comes out smaller, at level 6 by 0.2 % (dickens, xml) to 3.0 % (nci). On the [Canterbury corpus](https://corpus.canterbury.ac.nz/) the eleven files come to 722,392 bytes at level 6, against zlib's 730,888. Random bytes go into stored blocks, 5 bytes more for each 65,535; a long run of one byte costs a few bytes for each 64 KiB block. `moon run deflate/scripts/ratio.mbtx -- DIR` measures the sizes and the speed on a directory of files.

## Known limits

- Levels stop at 9: libdeflate's levels 10 to 12, whose near-optimal parsing comes out about 3 % smaller than level 9 at several times the time, are not here, and higher levels are clamped to 9.
- A flush is a sync flush: zlib's full flush, which also forgets the window, is not offered.

## License

Apache-2.0.
