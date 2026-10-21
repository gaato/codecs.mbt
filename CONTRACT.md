# The byte-stream codec contract

Every compression codec in this repository (a decoder or an encoder for one
compressed format) implements the same small contract, defined in
`gaato/codec_bytes` on top of the error and limit types of `gaato/codec`. Code
that moves bytes through a codec (an HTTP client, a gateway, a command-line
tool, the conformance suite) can then be written once against the contract,
and every codec is held to the same rules by the same tests.

The contract covers byte streams only: a byte stream in, a byte stream out.
Image and audio codecs produce pixels and samples, and have contracts of their
own that share `gaato/codec`'s errors and limits and follow the same rules
(see [ARCHITECTURE.md](ARCHITECTURE.md)). Archive and container formats that
have entries, directories or random access (tar, zip, the Shared Brotli
framing format) are layers on top of codecs, not codecs themselves.

## Types

```moonbit
// gaato/codec: shared by every kind of codec

#non_exhaustive
pub(all) enum ErrorKind {
  Truncated               // the input ended inside a stream
  Corrupt                 // the input is not a valid stream
  ChecksumMismatch        // a checksum or a declared length did not match
  TrailingData            // bytes follow the end of the stream
  LimitExceeded(Limit)    // a memory or output limit would be exceeded
  DictionaryRequired(UInt?) // the stream needs a dictionary (with its id, if any)
  DictionaryMismatch      // the dictionary given is not the one the stream needs
  Unsupported             // valid, but not implemented here (or not flushable)
}

pub(all) struct Limit { resource : Resource; needed : UInt64?; limit : UInt64 }

#non_exhaustive
pub(all) enum Resource { Memory; Output }

pub(all) suberror CodecError { CodecError(ErrorKind, String) }
```

```moonbit
// gaato/codec_bytes: byte streams

pub(all) enum Status {
  Done            // the stream is complete (see "Ending a stream")
  NeedMoreInput   // all input was consumed; call again with more
  NeedMoreOutput  // the output slice is full; call again with room
}

pub(all) enum Until {
  EndOfInput      // default: decode every member up to the end of the input
  EndOfMember     // stop right after the first member; leave the rest unread
}

pub(all) enum EncodeAction {
  Continue        // compress as convenient
  Flush           // make everything so far decodable without ending the stream
  Finish          // end the stream
}

pub(open) trait Decode {
  step(Self, BytesView, MutArrayView[Byte], end~ : Bool) -> Status raise @codec.CodecError
  last_consumed(Self) -> Int
  last_produced(Self) -> Int
  reset(Self) -> Unit
  memory_usage(Self) -> Int
}

pub(open) trait Encode {
  step(Self, BytesView, MutArrayView[Byte], action~ : EncodeAction) -> Status raise @codec.CodecError
  last_consumed(Self) -> Int
  last_produced(Self) -> Int
  reset(Self) -> Unit
  memory_usage(Self) -> Int
}
```

`Status`, `Until` and `EncodeAction` are exhaustive and will not grow: code
that matches on them stays complete. `ErrorKind` and `Resource` may gain
variants. Methods added to the traits later come with a default
implementation, so existing codecs keep compiling.

## The rules

Each call to `step` consumes a prefix of the input and writes a prefix of the
output slice; `last_consumed` and `last_produced` report how much.

1. **`NeedMoreInput` means everything is out.** The whole input was consumed,
   and every byte that this input determines has been written. A caller may
   treat "`NeedMoreInput` with nothing left to give" as a message boundary.
   Once `end` is `true`, a codec never asks for more input: it finishes, or
   raises `Truncated`.
2. **`NeedMoreOutput` means the slice is full.** A call with a non-empty
   output slice always makes progress or returns `NeedMoreInput`; looping on a
   codec cannot spin.
3. **Ending a stream.** With `Until::EndOfInput`, `Done` is returned only when
   `end` is `true` and the whole input was consumed. Bytes after a member that
   cannot begin another member raise `TrailingData`; bytes that begin another
   member but end inside it raise `Truncated`, as any cut stream does. With
   `Until::EndOfMember`, `Done` is returned right after the first member and
   nothing past it is consumed, so `input[last_consumed():]` is exactly what
   follows. Formats that cannot tell where a member ends without reading past
   it reject `EndOfMember` with `Unsupported`.
4. **Errors stick, and say how far the call got.** A call that raises
   reports in `last_consumed` and `last_produced` what it consumed and wrote
   before the error. A codec writes all the output that the input determines
   before the point of the error, and raises only once it is written: when
   the output slice fills first, the call returns `NeedMoreOutput`, and a
   later call writes the rest and raises. For `TrailingData`, `last_consumed`
   stops exactly at the end of the stream, so that `input[last_consumed():]`
   begins with the bytes after it; it is zero when an earlier call already
   took those bytes (a call takes all its input before it asks for more).
   Every later call raises the same kind and reports zero consumed and zero
   produced, until `reset`. A codec may document a resumable error on its own
   type (for example raising a memory limit and continuing); through the
   trait, every error is final.
5. **Splitting does not matter.** The output bytes and the error kind do not
   depend on how the input and the output are cut into slices. For a stream
   that raises, the output includes everything written before the error, so
   a corrupt stream gives the same bytes, then the same kind of error, under
   every split.
6. **Output before a checksum is provisional.** Bytes are written as soon as
   they are known. A checksum that covers them is checked afterwards, so
   `ChecksumMismatch` can follow output that the caller already has. The
   one-shot helpers (`decompress`) return only checked output.

`end~` has no default. A caller that forgets to say whether the input is
complete would otherwise get a silently truncated result.

`reset` returns the codec to the state of a new one with the same options. A
codec reused after `reset` behaves exactly as a fresh one.

`memory_usage` is the number of bytes the codec holds for the current stream
in buffers whose size depends on the stream (windows, blocks, tables sized by
a header). It never exceeds what the codec's limits allow, and it may drop
between members, when a codec releases what the next member does not need.

## Errors

Every codec raises `gaato/codec`'s `CodecError`, from its own methods as well
as through the traits, so that callers handle every format's failures with
one type. What is particular to a format goes in the message. A kind of
failure that no existing kind describes is added to `gaato/codec`; the enum
is `#non_exhaustive`, so adding one breaks no one.

## What the contract leaves to each format

These differ too much between formats to share one shape, so they live on the
concrete codec types:

- **Limits.** How much memory a stream may use is set in the format's own
  terms (a window in bits for zstd and brotli, a block size, a dictionary
  size). Exceeding it raises `LimitExceeded` with the size the stream needs
  and the size allowed, in bytes, for the structure the limit governs (the
  window, the block), so that callers can compare across formats. These are
  not totals: `memory_usage` counts everything the codec holds for the
  stream, which can be more.
- **Dictionaries**, given to the constructor.
- **Metadata** (a gzip header, a frame's declared size, the check type of an
  xz stream), read from the concrete type.
- **Encoder options** beyond the action (level, window, header fields).
- **Kinds of flush** beyond `Flush` (deflate's full flush). A format that
  cannot flush at all raises `Unsupported` for `Flush`.

## Formats checked against the contract

The contract was checked on paper against formats that are not implemented
here, so that adding one later does not require changing it.

| Format | Fit | Notes |
|---|---|---|
| Zstandard | implemented | Concatenated frames and skippable frames under `EndOfInput`. Dictionary ids map to `DictionaryRequired`. |
| Brotli | implemented | No framing: one stream per input, so `EndOfMember` and `EndOfInput` end at the same place. |
| gzip | implemented | Several members under `EndOfInput`; the header of each member is metadata on the concrete type. Bytes after a member that do not begin another, zero padding included, raise `TrailingData`. |
| zlib | implemented | A preset dictionary in the header raises `DictionaryRequired` with its Adler-32. No concatenation. |
| raw DEFLATE | implemented | No header and no checksum. Trailing bytes after the final block raise `TrailingData`. A `Corrupt` found inside the DEFLATE data does not yet report what its call wrote (rule 4); see gaato/deflate's README. |
| LZ4 frame | fits | Concatenated frames and skippable frames. The legacy frame has no end marker and rejects `EndOfMember`. |
| xz | fits | Several streams with padding. The memory limit is resumable on the concrete type. Filter chains that cannot flush raise `Unsupported`. |
| .lzma | fits | No magic and no checksum; trailing bytes are `TrailingData`. Cannot flush. |
| bzip2 | fits | Output appears a block at a time, which is consistent with rule 1. Its CRC is the MSB-first variant. |
| tar | not a codec | Entries need an event type, not `Status`. A tar reader follows the same habits (counts, `end~`, sticky errors, no reading ahead) on top of a codec. |

## Specifications

| Document | Status | Relevance |
|---|---|---|
| RFC 8878, Zstandard | Informational, updated by RFC 9659 | The zstd format. |
| RFC 9659, Window Sizing for Zstandard Content Encoding | Informational | HTTP's `zstd` coding is limited to an 8 MB window. |
| RFC 7932, Brotli | Informational, updated by RFC 9841 | The brotli format. |
| RFC 9841, Shared Brotli | Informational | Extends brotli with shared dictionaries, a large window (up to 62 bits) and a framing format. Not implemented. |
| RFC 9842, Compression Dictionary Transport | Proposed Standard | The `dcb` and `dcz` HTTP codings: a hash of the dictionary in a fixed header, then Shared Brotli or Zstandard. |
| RFC 1950, 1951, 1952 | Informational, neither updated nor obsoleted | zlib, DEFLATE and gzip, in gaato/deflate. Its errata (7764, 8429, 7517) clarify wording and change no decoder's behaviour. |
| LZ4 Frame Format, .xz File Format 1.2.1 | not RFCs | Used only for the paper check above. |

### Errata

The technical errata of Zstandard and Brotli, checked against the
decoders with crafted streams and the reference implementations (zstd 1.5.7,
google/brotli):

| Erratum | Status | Decoder behaviour |
|---|---|---|
| RFC 8878 6441, Appendix A tables | Verified | The predefined tables are computed from the default distributions, not copied, and match the correction. |
| RFC 8878 6442 and 8085, repeat offset example | Verified, Reported | Example only; offsets follow the corrected example and the reference decoder. |
| RFC 8878 7297, four streams need 6 literals | Verified | Fewer than 6 literals in four Huffman streams raise `Corrupt`. |
| RFC 8878 8668, treeless literals | Reported | A treeless block reuses the tree of the last compressed literals block in the frame, across raw and RLE blocks. |
| RFC 8878 9223, reserved dictionary ids | Reported | Any non-zero dictionary id is refused unless that dictionary is available. |
| RFC 8878 9227, reserved bits of the sequences header | Reported | Non-zero reserved bits raise `Corrupt`, as zstd 1.5.7 does. |
| RFC 8878 9228, content checksum | Reported | The checksum is always verified. |
| RFC 7932 6977, implicit zero distance | Reported | The distance block count is not decremented for an implicit distance, as in the reference decoder; streams from google/brotli at quality 5, 9 and 11 that reach this case decode. |
