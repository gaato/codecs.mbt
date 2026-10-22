# The codec contracts

Every compression codec in this repository (a decoder or an encoder for one
compressed format) implements the same small contract, defined in
`gaato/codec_bytes` on top of the error and limit types of `gaato/codec`. Code
that moves bytes through a codec (an HTTP client, a gateway, a command-line
tool, the conformance suite) can then be written once against the contract,
and every codec is held to the same rules by the same tests.

That contract covers byte streams only: a byte stream in, a byte stream out.
Image decoders produce rows of pixels, and have a contract of their own,
`gaato/codec_image`, described in the second part of this document,
[Images](#images): it shares `gaato/codec`'s errors and limits and reads the
same rules in units of rows. Audio codecs, which produce samples, would have
theirs (see [ARCHITECTURE.md](ARCHITECTURE.md)). Archive and container
formats that have entries, directories or random access (tar, zip, the
Shared Brotli framing format) are layers on top of codecs, not codecs
themselves.

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

pub using @codec {type CodecError, type ErrorKind, type Limit, type Resource}

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

## Streams that do not end

Some streams are meant never to end. Discord's gateway compresses a whole
connection as one zlib stream (`zlib-stream`) and ends each message with a
sync flush, `00 00 ff ff`; `zstd-stream` is one zstd frame per connection,
each message flushed to a block boundary. A consumer keeps one decoder for
the connection and passes every piece of input with `end=false`, since the
input has no last piece:

- **`NeedMoreInput`**, with the input consumed, is the normal answer to every
  piece. By rule 1 everything the input determines has been written, so once
  a piece that ends on a flush has been consumed, the whole message is out.
  The decoder does not know where messages end: a message that arrives in
  several pieces answers `NeedMoreInput` after each, and the consumer finds
  the end from its own framing (for `zlib-stream`, the flush suffix).
- **`NeedMoreOutput`**: the slice is full. Call again with what is left of the
  piece (`input[last_consumed():]`) and more room.
- **`Done`**: the stream ended, which such a stream must not do. Make the
  decoder with `until=EndOfMember`, so that an end is reported at once and
  nothing after it is consumed. Under the default `EndOfInput` and
  `end=false`, a decoder after the end of a stream waits to see what follows,
  answering `NeedMoreInput`; the next bytes then raise `TrailingData`, or
  for gzip and zstd are read as another member.

When the connection closes, the stream has been cut, not ended: drop the
decoder, or `reset` it for the next connection. Passing `end=true` instead
raises `Truncated`, which is right only for a consumer that wants to know the
stream was cut. Memory stays what `memory_usage` reports however long the
stream runs: a decoder keeps its window, never the output so far.

## Errors

Every codec raises `gaato/codec`'s `CodecError`, from its own methods as well
as through the traits, so that callers handle every format's failures with
one type. `gaato/codec_bytes` re-exports `CodecError`, `ErrorKind`, `Limit`
and `Resource`, so a consumer of byte-stream codecs names them with that one
import. In a `catch` on a codec's step, where the error's type is known,
`CodecError(kind, message)` and the kinds match unqualified and need no
import at all; elsewhere, qualify a constructor by its type, as in
`@codec_bytes.CodecError::CodecError(kind, _)`. What is particular to a format goes in the message. A kind of
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
| Zstandard | implemented (Decode) | Concatenated frames and skippable frames under `EndOfInput`. Dictionary ids map to `DictionaryRequired`. |
| Brotli | implemented (Decode and Encode) | No framing: one stream per input, so `EndOfMember` and `EndOfInput` end at the same place. |
| gzip | implemented (Decode and Encode) | Several members under `EndOfInput`; the header of each member is metadata on the concrete type. Bytes after a member that do not begin another, zero padding included, raise `TrailingData`. |
| zlib | implemented (Decode and Encode) | A preset dictionary in the header raises `DictionaryRequired` with its Adler-32. No concatenation. |
| raw DEFLATE | implemented (Decode and Encode) | No header and no checksum. Trailing bytes after the final block raise `TrailingData`. |
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

# Images

Image decoders implement a contract of their own, defined in
`gaato/codec_image` on top of the same errors and limits of `gaato/codec`.
It keeps the rules of byte streams above, read in units of rows: a decoder
writes whole rows into the caller's slice, and stops to say what it wrote or
what it found. Code that steps an image decoder (an image viewer, a
thumbnailer, a format converter, the conformance suite) can then be written
once against the contract.

The rules have the same content as those of byte streams but not the same
shape, which is why they are a part of their own. A step does one thing and
says which: a step that writes answers `Rows` or `Metadata`, and every other
answer comes from a step that wrote nothing. A step that raises writes
nothing either: the rows and events before an error come out in the steps
before it, where a byte-stream codec writes the output before an error in
the step that raises.

The contract covers decoders that read an image from a byte stream. Pixel
layouts, palettes, colour information, animation timing and metadata differ
too much between formats to share one shape, and live on each format's own
type (see "What the contract leaves to each format" below).

## Types

```moonbit
// gaato/codec_image

pub using @codec {type CodecError, type ErrorKind, type Limit, type Resource}

pub(all) enum Status {
  Header          // the image's header is read: width and height are known
  Frame           // a frame begins: its rectangle is known
  Rows            // whole rows of one pass of the frame were written
  Metadata        // a block of metadata that was asked for was written whole
  FrameEnd        // the frame's last row is out and its data passed every check
  Done            // the image is complete
  NeedMoreInput   // all input was consumed; call again with more
  NeedMoreOutput  // the slice cannot hold the next row or block; see room_needed
}

pub(all) enum Until {
  EndOfInput      // default: decode the image up to the end of the input
  EndOfMember     // stop right after the image; leave the rest unread
}

pub(open) trait Decode {
  step(Self, BytesView, MutArrayView[Byte], end~ : Bool) -> Status raise @codec.CodecError
  last_consumed(Self) -> Int
  last_produced(Self) -> Int
  reset(Self) -> Unit
  memory_usage(Self) -> Int
  room_needed(Self) -> Int
  // the canvas, from Header
  width(Self) -> Int
  height(Self) -> Int
  // the current frame, from Frame
  frame_x(Self) -> Int
  frame_y(Self) -> Int
  frame_width(Self) -> Int
  frame_height(Self) -> Int
  // the last Rows
  pass(Self) -> Int
  pass_x(Self) -> Int
  pass_y(Self) -> Int
  pass_dx(Self) -> Int
  pass_dy(Self) -> Int
  rows_first(Self) -> Int
  rows_count(Self) -> Int
  row_bytes(Self) -> Int
}
```

`Status` and `Until` are exhaustive and will not grow. `Status` is a type of
its own, not the byte streams' `Status` with more variants, so that code
matching on either stays complete. Numbers are read from the decoder, never
returned as a tuple or a struct, which native code would allocate on the
heap at every step; each accessor says from when to when it is valid, and
outside that its value is unspecified.

| Accessors | Valid |
|---|---|
| `width`, `height` | from `Header` until `reset` |
| `frame_x`, `frame_y`, `frame_width`, `frame_height` | from `Frame` until the next `Frame` or `Done` |
| `pass`, `pass_x`, `pass_y`, `pass_dx`, `pass_dy`, `rows_first`, `rows_count`, `row_bytes` | after `Rows`, until the next step |
| `room_needed` | after every step |

## How an image comes out

A decoder reports, in this order:

- `Header`, once, before any frame. `Metadata` may come before it: some
  formats put metadata ahead of their header (JPEG's application segments
  precede its frame header).
- zero or more frames, each one `Frame`, then its rows in `Rows`, then
  `FrameEnd`. A still image is one frame. Frames do not overlap in time:
  a frame ends before the next begins.
- `Done`, after the last frame.

`Metadata` may come at any point before `Done`, inside a frame too (JPEG
allows application segments between the scans of a frame). A decoder
reports metadata only when it was asked to, through options of its own
type; by default it reports none.

**Frames.** A frame is a rectangle of the canvas: columns `frame_x` to
`frame_x + frame_width`, rows `frame_y` to `frame_y + frame_height`,
always inside the canvas. A format whose files may declare frames outside
the canvas documents whether its decoder clips them or rejects them.

**Passes.** A frame's rows come out in passes, numbered upwards from 0; an
image that is not interlaced has the one pass 0. A pass is a lattice of the
frame: row `r` of the pass is row `pass_y + r * pass_dy` of the frame, and
pixel `i` of that row is column `pass_x + i * pass_dx`. The pass therefore
has `ceil((frame_height - pass_y) / pass_dy)` rows of
`ceil((frame_width - pass_x) / pass_dx)` pixels, or none when either is
not positive. A pass with no pixels is skipped: nothing is reported for it.
Each pass delivers all of its rows, in order from row 0, before the next
pass begins, and all the rows of one `Rows` belong to one pass. A later
pass may cover pixels an earlier one already gave (a format that refines
the whole image scan by scan); its rows then replace them.

**Rows.** `Rows` wrote `rows_count` rows (at least one) of `row_bytes`
bytes each (at least one), rows one after another with nothing between
them, starting at row `rows_first` of the pass: `last_produced` is
`rows_count * row_bytes`. The bytes of a row are the format's own layout of
the pass's pixels.

**Metadata.** `Metadata` wrote one block whole, of `last_produced` bytes.
What the block is (a PNG chunk's type, a JPEG segment's marker) is read
from the format's own type.

## The rules

The rules of byte streams hold, read in units of output: a row, or a block
of metadata.

1. **`NeedMoreInput` means everything is out.** The whole input was
   consumed, and every event and every whole row that this input determines
   has been delivered, by this step or an earlier one. What the input
   determines is measured against what the decoder produces: a decoder that
   writes a progressive JPEG once, at its end, determines no row before its
   last scan. Once `end` is `true`, a decoder never asks for more input: it
   finishes, or raises `Truncated`.
2. **`NeedMoreOutput` means the next unit does not fit.** A decoder writes
   whole rows and whole blocks of metadata only. `NeedMoreOutput` means one
   is ready and the slice is shorter than it; `room_needed` then says how
   long it is, and nothing was written. A step that writes, writes one
   thing: rows of one pass (`Rows`) or one block (`Metadata`); every other
   answer writes nothing. A call whose slice holds `room_needed` bytes
   always makes progress or returns `NeedMoreInput`, so looping on a decoder
   with that much room cannot spin.
3. **Ending an image.** With `Until::EndOfInput`, `Done` is returned only
   when `end` is `true` and the whole input was consumed; bytes after the
   image raise `TrailingData`. With `Until::EndOfMember`, `Done` is returned
   right after the image and nothing past it is consumed, so
   `input[last_consumed():]` is exactly what follows. Every format checked
   below can tell where its image ends without reading past it.
4. **Errors stick, and say how far the call got.** A decoder delivers every
   event and writes every whole row that the input determines before the
   point of the error, and raises only once they are out: they come in the
   steps before the one that raises, which writes nothing and reports in
   `last_consumed` what it consumed. For `TrailingData`, `last_consumed`
   stops exactly at the end of the image, as for byte streams. Every later
   call raises the same kind and reports zero consumed and zero produced,
   until `reset`. Through the trait, every error is final.
5. **Splitting does not matter.** The rows' bytes in order, the blocks of
   metadata, the events in order with what their accessors report (the
   header's size, each frame's rectangle, the pass of each row), and the
   error kind do not depend on how the input is cut into slices or how much
   room each step has. Only how rows are grouped into steps depends on the
   room.
6. **Output before a checksum is provisional.** Rows are written as soon as
   they are known. A checksum that covers them is checked afterwards, so
   `ChecksumMismatch` can follow rows that the caller already has.
   `FrameEnd` comes only once every check covering the frame's data has
   passed. The one-shot helpers (`decode`) return only checked output.

`end~` has no default, and `reset` and `memory_usage` mean what they mean
for byte streams: `memory_usage` counts the bytes held for the current
image in buffers whose size depends on it (rows, windows, tables sized by
the header, metadata held until its checksum is checked) and never exceeds
what the decoder's limits allow. A decoder does not hold a whole frame
unless the format leaves no choice; where it must buffer, the buffer is a
limit of the decoder's own type, and exceeding it raises `LimitExceeded`
with the bytes of that structure, as for byte streams.

## What the contract leaves to each format

These live on the format's own decoder type:

- **The pixel layout** of its rows, and the functions that convert them
  (to RGBA, applying a palette, expanding samples).
- **Palettes and colour information** (PLTE and tRNS, colour spaces, ICC
  profiles read as fixed fields). Values that describe a frame, such as
  GIF's local colour table, keep the validity of the frame accessors.
- **Animation:** delays, disposal, blending, loop counts, and whether a
  frame belongs to the animation (a PNG's default image may not).
- **Metadata:** which blocks are reported, how to ask for them, and what
  each block is.
- **Limits**, in the format's own terms (bytes of a row, of a window, of a
  block of metadata), and options such as decoding only the first frame.

## Formats checked against the image contract

The contract was checked on paper against image formats that are not
implemented here, so that adding one later does not require changing it.

| Format | Fit | Notes |
|---|---|---|
| PNG and APNG | fits | `Header` at IHDR. Each frame is reported when its first data chunk begins, so that every chunk the format places before image data is known by then. Adam7's seven passes are lattices: pass 2 starts at column 4 with a step of 8, and so on; empty passes are skipped. `FrameEnd` comes after the CRCs of the frame's last data chunks and the Adler-32 of its zlib stream. A default image that is not part of the animation is still a frame, marked on PNG's type. Text chunks between frames are `Metadata` inside the sequence. |
| WebP lossless | fits, with buffering stated as limits | Rows come out as soon as they are decoded, since every inverse transform needs only the current row and the one above. Backward references reach at most 1,048,456 pixels back (about 4 MiB of ARGB), so the window is a limit that stays the same however large the image. The predictor, colour and entropy images precede the pixels and are held whole (each at most one 4-byte entry for every 16 pixels), and so are the prefix codes of up to 65,536 groups: limits in their own terms. |
| WebP animation (ANIM, ANMF) | fits | Each ANMF is a frame, inside the canvas as the format requires. Disposal and blending are on WebP's type. Lossy frames with alpha keep their ALPH data until the VP8 rows it belongs to: a limit. EXIF and XMP usually follow the image data, so their `Metadata` comes after the last `FrameEnd`. |
| GIF | fits | `Header` at the logical screen descriptor; each image is a frame, with its local colour table valid from `Frame`. Interlaced images arrive in their four passes, full rows each (rows 0, 8, ...; 4, 12, ...; 2, 6, ...; 1, 3, ...), so no image is held. A file with no image at all (only a colour table) is `Header`, then `Done`. Frames that stick out of the logical screen, common in files despite the specification, are clipped or rejected, as the decoder documents. |
| JPEG, baseline and extended | fits, with buffering stated as limits | Application segments (JFIF, Exif, ICC, XMP) precede the frame header, so `Metadata` can come before `Header`. Interleaved scans give rows by bands of MCUs; scans of one component each need the earlier components held whole, a limit. Heights defined later by a DNL segment, and hierarchical frames, raise `Unsupported`. |
| JPEG, progressive | fits, with buffering stated as limits | The coefficients of the whole image are held, a limit. Rows come out once, after the last scan; a decoder may instead offer a pass of the whole frame after each scan, each pass replacing the last. |
| QOI | fits | Rows come out pixel by pixel with a 64-entry index and the previous pixel as all the state; a run may cross rows. Its size fields allow more than 2^31 − 1 pixels a side, which the decoder rejects. |

## Specifications

| Document | Status | Relevance |
|---|---|---|
| Portable Network Graphics (PNG) Specification (Third Edition) | W3C Recommendation, 2025-06-24 | PNG and APNG. Its one erratum (an example's hexadecimal in mDCV) changes no decoder's behaviour. |
| RFC 9649, WebP Image Format | Informational | The RIFF container, animation, and the lossless and lossy bitstreams. |
| Graphics Interchange Format, Version 89a | CompuServe, 1990 | GIF. |
| ITU-T T.81 (ISO/IEC 10918-1), with JPEG File Interchange Format 1.02 | Recommendation, 1992 | JPEG, and the placement of the JFIF segment. |
| The Quite OK Image Format, Specification Version 1.0 | 2022-01-05 | QOI. |
