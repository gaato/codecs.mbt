# Resource bounds

What the decoders of the three packages hold, and what keeps each structure
from growing without limit. The rule: **every structure that grows with the
input is listed here with its bound**. A new one needs a row before it ships.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests. A test counts only if it drives the structure to its limit, or checks
the bound after every step over streams that push it. `scripts/bounds_check.mbtx`,
run by `scripts/gates.mbtx`, enforces the naming; whether a named test really
reaches the bound is checked in review. The other tables are prose.

The raw DEFLATE decoder holds moonbit-community/flate 0.9.0's `Inflater`,
whose arrays it cannot see. Their bounds below come from that version's source
(`inflate.mbt`, `huffman_table.mbt`): `memory_usage` reports their sum as a
constant, and the tests check what it reports. A new version of the inflater
needs these rows checked again.

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|
| Window (`src/decoder.mbt`, the inflater's `window`) | 32 KiB, the most RFC 1951 lets a distance reach, allocated when the decoder is made. A zlib header's smaller window (CINFO) is checked to be at most 32 KiB and not used to limit distances, as zlib does | A distance before the start of the output (or of the dictionary) raises `Corrupt` | `src/bounds_wbtest.mbt`: "output slices and reported memory stay within their bounds"; `src/reference_wbtest.mbt`: "crafted streams: the decoder answers as zlib does" |
| Second-level Huffman tables (`src/decoder.mbt`, the inflater's `links`) | 40,448 bytes: entries of 4 bytes, 64 for each 9-bit prefix of codes longer than 9 bits, and each such prefix holds at least two codes of a complete code, so at most 143 prefixes for the 286 literal/length codes and 15 for the 30 distance codes. Rebuilt for every dynamic block | Cannot overflow: an over-subscribed or incomplete code is refused before a table is built | `src/bounds_wbtest.mbt`: "output slices and reported memory stay within their bounds"; `src/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| Unfinished unit (`src/decoder.mbt`, the inflater's `staged_input`) | 1 KiB: the bytes of one unit the input cut short, at most 286 for the longest unit, a dynamic block header of 2,286 bits, in an array that may double. Every other input byte is decoded | Cannot overflow: a unit that has its bytes completes | `src/bounds_wbtest.mbt`: "output slices and reported memory stay within their bounds"; `src/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| Preset dictionary (`src/decoder.mbt`, `dictionary`) | A view of its last 32 KiB, to load the window again at `reset`: the caller's bytes, held by reference and not copied (see "Left to the caller"); the inflater's window holds the same bytes | Cannot overflow: a view of the last 32 KiB, whatever the dictionary's length | `src/bounds_wbtest.mbt`: "only the last 32 KiB of a dictionary are kept, by reference" |
| Output slice (`Decoder::step`, `Decoder::step_into` of each package) | At most the caller's buffer per step, down to 1 byte; the rest of a match waits in the inflater | `NeedMoreOutput` | `src/bounds_wbtest.mbt`: "output slices and reported memory stay within their bounds"; `src/zlib/bounds_wbtest.mbt`: "output slices, header bytes and reported memory stay within their bounds"; `src/gzip/bounds_wbtest.mbt`: "output slices, header fields and reported memory stay within their bounds" |
| Raw DEFLATE memory (`@deflate.Decoder::memory_usage`) | The window, the second-level tables and the unfinished unit above: 74,240 bytes, with a dictionary or without. The same from the first step to the last | Cannot overflow: each part is bounded by its own row | `src/bounds_wbtest.mbt`: "output slices and reported memory stay within their bounds", "only the last 32 KiB of a dictionary are kept, by reference"; `src/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| zlib header and trailer bytes (`src/zlib/decoder.mbt`, `hdr`) | 6 bytes: CMF, FLG and DICTID; the trailer's 4 bytes reuse them | Cannot overflow | `src/zlib/bounds_wbtest.mbt`: "output slices, header bytes and reported memory stay within their bounds" |
| zlib inner decoder (`src/zlib/decoder.mbt`, `inner`) | One raw DEFLATE decoder, made when the first header says whether the stream names a preset dictionary (FDICT), before any DEFLATE byte: with the dictionary for a stream that names it, without otherwise; 74,240 bytes either way. A later stream of the same kind resets it; one of the other kind replaces it | Cannot overflow: one decoder at a time | `src/zlib/bounds_wbtest.mbt`: "one inner decoder, made for the kind of stream the header names", "output slices, header bytes and reported memory stay within their bounds" |
| zlib dictionary (`src/zlib/decoder.mbt`, `dictionary`) | A view of the preset dictionary's last 32 KiB, held by reference and not copied, to make an inner decoder with it; its Adler-32 is taken over the whole dictionary when the decoder is made | Cannot overflow: a view of the last 32 KiB, whatever the dictionary's length | `src/zlib/bounds_wbtest.mbt`: "one inner decoder, made for the kind of stream the header names" |
| zlib memory (`@zlib.Decoder::memory_usage`) | The inner decoder above: 0 before the first header and 74,240 after it, with a dictionary or without | Cannot overflow: each part is bounded by its own row | `src/zlib/bounds_wbtest.mbt`: "output slices, header bytes and reported memory stay within their bounds", "one inner decoder, made for the kind of stream the header names"; `src/zlib/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| gzip fixed header and trailer bytes (`src/gzip/decoder.mbt`, `hdr`) | 10 bytes: the fixed part of a header; the extra field's length, the header CRC and the trailer's two halves reuse them | Cannot overflow | `src/gzip/bounds_wbtest.mbt`: "output slices, header fields and reported memory stay within their bounds" |
| gzip header fields (`src/gzip/decoder.mbt`, `extra`, `name`, `comment`, `header`) | `max_header_bytes` (65,536 by default) for the extra field, the name and the comment together, without the name's and the comment's terminating zeros. The extra field is checked against it from its declared length, before its buffer is allocated; a name or a comment as it gathers. The previous member's header is dropped when the next one's fixed part is read, so one header is held at a time | `LimitExceeded({ resource: Memory, needed, limit: max_header_bytes })`, `needed` the fields' size with the extra field's declared length, None for a name or a comment | `src/gzip/decode_wbtest.mbt`: "max_header_bytes bounds the extra field, the name and the comment together", "header() follows the members"; `src/gzip/bounds_wbtest.mbt`: "output slices, header fields and reported memory stay within their bounds" |
| gzip memory (`@gzip.Decoder::memory_usage`) | The raw DEFLATE decoder and the header fields held: at most `74,240 + max_header_bytes` bytes. It drops when a member's header is dropped, and to the decoder's at `reset` | Cannot overflow: each part is bounded by its own row | `src/gzip/bounds_wbtest.mbt`: "output slices, header fields and reported memory stay within their bounds"; `src/gzip/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| One-shot output (`decompress` of each package, `max_output`) | `max_output` bytes when given; unlimited by default | `LimitExceeded({ resource: Output, needed: None, limit: max_output })` | `src/decode_wbtest.mbt`: "decompress honours max_output"; `src/zlib/decode_wbtest.mbt`: "decompress honours max_output"; `src/gzip/decode_wbtest.mbt`: "decompress honours max_output, over all members" |

## Fixed per decoder

| Structure | Size |
|---|---|
| The inflater's first-level Huffman tables (literal/length and distance) | 2 × 512 entries of 4 bytes: 4 KiB |
| The inflater's code lengths | 316 + 19 entries of 4 bytes: about 1.3 KiB |
| Checksum state: Adler-32 (zlib), CRC-32 and length (gzip), the header's CRC-32 | A few words |
| The fixed Huffman table, the CRC-32 table | 2 KiB and 1 KiB, shared by all decoders |

## Left to the caller

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| Total output of a stream | The stream | `step` hands it out in slices; the caller decides what to keep |
| Input chunks | What the caller passes | `step` keeps no reference to them after it returns; what it needs it copies |
| A preset dictionary's bytes | The dictionary the caller gives the raw DEFLATE or zlib `Decoder` | The decoder keeps a view of its last 32 KiB, which keeps the whole `Bytes` it belongs to alive as long as the decoder. A caller whose dictionary is a slice of a larger buffer it wants freed passes a copy of the slice |
| A gzip stream's members | The stream | Each is decoded and checked in turn; nothing of an earlier member is kept but the last header |
| `decompress` output | The stream | It returns the whole output; pass `max_output`, or use `Decoder` |
