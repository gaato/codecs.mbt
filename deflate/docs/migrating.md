# Moving from MoonBit's core library or moonbit-community/flate

`gaato/deflate`'s one-shot functions have the same shape as those of
`moonbitlang/core/compress` and of `moonbit-community/flate`, whose code went
into the core library (moonbitlang/core#4459). For zlib and gzip decoding,
most code moves by changing the import; compression levels, the error types
and a few defaults need more. This page lists them, and where the
implementations behave differently.

The names here are those of `moonbit-community/flate` 0.10.0 and of the core
library in MoonBit 0.10.20, whose compression packages are experimental. The
core library renames some of them on its main branch, such as `max_output` to
`max_output_bytes` (moonbitlang/core#4798).

## Packages

| core library | moonbit-community/flate 0.10.0 | gaato/deflate |
| --- | --- | --- |
| `moonbitlang/core/compress/flate` | `moonbit-community/flate` | `gaato/deflate` |
| `moonbitlang/core/compress/zlib` | `moonbit-community/flate/zlib` | `gaato/deflate/zlib` |
| `moonbitlang/core/compress/gzip` | `moonbit-community/flate/gzip` | `gaato/deflate/gzip` |
| `moonbitlang/core/archive/zip` | `moonbit-community/flate/zip` | none yet |

## One-shot functions

| core library | moonbit-community/flate 0.10.0 | gaato/deflate |
| --- | --- | --- |
| `@zlib.decompress(data, dictionary?, max_output?)` | `@zlib.decompress(data)` | `@zlib.decompress(data, dictionary?, max_output?)` |
| `@gzip.decompress(data, max_output?)` | `@gzip.decompress(data)` | `@gzip.decompress(data, max_output?)` |
| `@flate.inflate_exact(data, dictionary?, max_output?)` | `@flate.inflate_exact(data, max_output?)` | `@deflate.decompress(data, dictionary?, max_output?)` |
| `@flate.inflate_prefix(data, ...)`, which returns `consumed` too | `Decompressor::decompress(data)`, then `last_consumed()` | a `Decoder(until=EndOfMember)`, adding up `last_consumed()` over its steps (see [Streaming](#streaming)) |
| `@zlib.compress(data, strategy=Standard(level=6))` | `@zlib.compress(data, level=6)` | `@zlib.compress(data, level=6)` |
| `@gzip.compress(data, strategy=...)` | `@gzip.compress(data, level=...)` | `@gzip.compress(data, level?, header?)` |
| `@flate.deflate_all(data, strategy?, dictionary?)` | `@flate.deflate_all(data, level?)` | `@deflate.compress(data, level?, dictionary?, window_bits?)` |
| `@flate.deflate_bound(n)`, `Int` to `Int` | `@flate.deflate_bound(n)`, `Int` to `Int` | `@deflate.compress_bound(n)`, `Int64` to `Int64`; `@zlib` and `@gzip` have their own |

Levels 0 to 9 mean the same in all three: 0 stores, 1 is the fastest, 9 the
smallest, 6 the default. Level -1 differs: the core library and
moonbit-community/flate clamp it to 0 and store, while gaato/deflate takes it
as zlib's `Z_DEFAULT_COMPRESSION`, level 6.

`cancelled?`, `two_pass?`, `fast_store?` and moonbit-community/flate's
`preallocated?` have no counterpart: a one-shot call of gaato/deflate runs to
the end, and a caller who wants to stop part-way uses a `Decoder` and stops
calling `step`.

## Errors

The core library has one error type per package; gaato/deflate raises
`@codec.CodecError(kind, message)` from every package, so one `catch` covers
all of them, and the same kinds come from gaato's other formats.

| core library | gaato/deflate (`ErrorKind`) |
| --- | --- |
| `Truncated` | `Truncated` |
| `Corrupt`, `InvalidDeflate`, `InvalidHeader` | `Corrupt`; a gzip header whose FHCRC does not match is `ChecksumMismatch` |
| `ChecksumMismatch`, gzip's `LengthMismatch` | `ChecksumMismatch` |
| `TrailingData` | `TrailingData` |
| `DictionaryRequired` | `DictionaryRequired(Some(id))`, with the dictionary's Adler-32 |
| `DictionaryMismatch` | `DictionaryMismatch` |
| `OutputLimitExceeded(limit~, observed~)` | `LimitExceeded({ resource: Output, needed, limit })` |
| `InvalidArgument`, as for a negative `max_output` | a negative `max_output` raises `LimitExceeded` with a limit of 0 |
| `Cancelled` | none |

## Streaming

The core library's decoders return a `StepResult` with `status`, `consumed`
and `produced`; gaato/deflate's return a `Status` (`Done`, `NeedMoreInput`,
`NeedMoreOutput`), and `last_consumed()` and `last_produced()` give the counts
of that step. Each step also says whether its input is the last.
moonbit-community/flate's `Inflater` already works this way.

| core library | gaato/deflate |
| --- | --- |
| `IncrementalDecoder(dictionary?)`, `@zlib.Decoder(dictionary?)` | `@deflate.Decoder(dictionary?, until=EndOfMember)`, `@zlib.Decoder(dictionary?, until=EndOfMember)` |
| `@gzip.Decoder()` (`multistream=true`) | `@gzip.Decoder()` |
| `@gzip.Decoder(multistream=false)` | `@gzip.Decoder(until=EndOfMember)` |
| `step(input, output)` | `step(input, output, end~)`; `step_into` takes a `FixedArray` |
| zlib's and gzip's `check_end()` after the last input; for `IncrementalDecoder`, `NeedMoreInput` at the end of the input | `end=true` with the last input: a stream cut short raises `Truncated` |
| zlib's and gzip's `unused_input()`; for `IncrementalDecoder`, the input past `StepResult.consumed` | under `until=EndOfMember`, `input[last_consumed():]` of the step that answered `Done` |
| `IncrementalEncoder(level?)`, `step(input, output, action?)` | `@deflate.Encoder(level?)`, `step(input, output, action~)` |
| `DeflateAction::SyncFlush` | `Flush` |

The core library's raw and zlib decoders stop at the end of the stream and
leave what follows to the caller; gaato/deflate's do so under
`until=EndOfMember`, as in the table. Under the default, `until=EndOfInput`,
they read to the end of the input and refuse bytes after the stream with
`TrailingData`.

`reset` keeps the dictionary in gaato/deflate. The core library's
`reset(dictionary?)` without a dictionary clears it; with gaato/deflate's raw
decoder, `reset(dictionary=b"")` does, and its other decoders and encoders keep
the dictionary they were made with.

## What behaves differently

- Bytes after a gzip stream that do not begin another member: the core
  library's `@gzip.decompress` ignores them; gaato/deflate raises
  `TrailingData`, as zlib does, and zero padding is no exception. (Bytes that
  begin a member and end inside its header are `Truncated` in both.)
- Bytes after a zlib stream are `TrailingData` in both.

## Why these differences stay

- One error type, `CodecError`, and one step shape (`Status`, `last_consumed()`,
  `end~`) are the contract every codec in codecs.mbt keeps, so code written for
  one format works for the others; `end~` is what lets a decoder tell a stream
  cut short from one that ended.
- Refusing bytes after a stream by default, as zlib does, keeps data from being
  dropped without a word.
- Level -1 is zlib's spelling of the default level.
- `compress_bound` takes and returns `Int64` so that it can bound inputs past
  2 GiB.
- `decompress` and `compress` are the names in every format of codecs.mbt.
- `reset()` starts over with the options the decoder or encoder has, in every
  format: those it was made with, or for the raw decoder's dictionary, the one
  its last `reset(dictionary=...)` gave.
- `max_output` keeps its name until the core library's names settle: they are
  still changing while its compression packages are experimental.

## What gaato/deflate adds

- gzip headers: `Decoder::header()` reads the name, comment, modification time,
  extra field and the rest, with `max_header_bytes` bounding them;
  `compress(header~)` writes them.
- `window_bits` (8 to 15) for the raw and zlib encoders, for a peer that keeps
  less than 32 KiB of history, as WebSocket's permessage-deflate negotiates.
- `Decoder::at_block_boundary()` and `reset(dictionary?)`, for formats that cut
  a stream at sync flushes.
- Memory bounds before decoding or encoding: `decoder_memory_bound()`,
  `encoder_memory_bound(level~)`, and `memory_usage()` on every decoder and
  encoder.
- Versions of its own: a release of MoonBit does not change the API.
- Zstandard, Brotli, LZ4, Snappy and LZW with the same byte-stream API, and a
  PNG decoder with its image counterpart, in
  [codecs.mbt](https://github.com/gaato/codecs.mbt).

## What the core library has and gaato/deflate does not

- ZIP archives (`archive/zip`).
- The `Split` and `Optimal` strategies, which can give smaller output than
  level 9 for more time.
- `cancelled`, `two_pass` and `fast_store` in the one-shot functions (see
  [One-shot functions](#one-shot-functions)).
