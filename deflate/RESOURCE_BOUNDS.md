# Resource bounds

What the decoders and the encoders of the three packages hold, and what keeps
each structure from growing without limit. The rule: **every structure that grows with the
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

The raw DEFLATE encoder likewise holds flate 0.9.0's `Deflater`. Its arrays'
bounds come from that version's source (`deflate.mbt`, `block_planner.mbt`,
`lz77.mbt`, `block_writer.mbt`) and are checked against it:
`scripts/flate_bounds.mbtx` (run in CI) runs a white-box test,
`scripts/flate_bounds/deflater_bounds_wbtest.mbt`, inside a copy of the flate
module this one depends on, which reads the deflater's private arrays after
every step over every level, with and without a dictionary, under splits and
flushes around a block's size, and checks each bound below; their sum is
reached. Run it again when the dependency changes version. Sizes count 4
bytes for an `Int` and 1 for a `Byte`, as on native and Wasm.

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
| gzip header fields (`src/gzip/decoder.mbt`, `extra`, `name`, `comment`, `header`) | `max_header_bytes` (65,536 by default) for the extra field, the name and the comment together, without the name's and the comment's terminating zeros. The extra field is checked against it from its declared length, before its buffer is allocated; a name or a comment as it gathers. The previous member's header is dropped when the next one's fixed part is read, so one header is held at a time. With `keep_header=false`, as in `decompress`, none of these bytes are held, whatever their size: they only pass through the header CRC, and `max_header_bytes` does not apply | `LimitExceeded({ resource: Memory, needed, limit: max_header_bytes })`, `needed` the fields' size with the extra field's declared length, None for a name or a comment | `src/gzip/decode_wbtest.mbt`: "max_header_bytes bounds the extra field, the name and the comment together", "header() follows the members", "keep_header=false skips fields of any size, holding none of them"; `src/gzip/bounds_wbtest.mbt`: "output slices, header fields and reported memory stay within their bounds" |
| gzip memory (`@gzip.Decoder::memory_usage`) | The raw DEFLATE decoder and the header fields held: at most `74,240 + max_header_bytes` bytes, and 74,240 with `keep_header=false`. It drops when a member's header is dropped, and to the decoder's at `reset` | Cannot overflow: each part is bounded by its own row | `src/gzip/bounds_wbtest.mbt`: "output slices, header fields and reported memory stay within their bounds"; `src/gzip/decode_wbtest.mbt`: "keep_header=false skips fields of any size, holding none of them"; `src/gzip/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| Encoder input ring (`src/encoder.mbt`, the deflater's `pending`) | 128 KiB: a 64 KiB ring, mirrored for wide loads, that holds the 32 KiB window and the input waiting to be encoded, at most 16,642 bytes (a 16 KiB block and the 258 bytes a match may look ahead). Allocated when the encoder is made | Cannot overflow: a step takes input only until a block and its look-ahead wait, and encodes that block before it takes more | `src/bounds_wbtest.mbt`: "the encoder holds at most a block of input and its output"; `scripts/flate_bounds/deflater_bounds_wbtest.mbt`: "the deflater's arrays stay within the bounds gaato/deflate counts" |
| Encoder match finder (`src/encoder.mbt`, the deflater's `finder`) | 458,754 bytes: 32,768 heads for 3-byte matches and 65,536 for 4-byte ones, 4 bytes each, and the backward distances of the 32 KiB window, 2 bytes each. Allocated when the encoder is made; the streaming deflater never resizes them | Cannot overflow: fixed sizes | `scripts/flate_bounds/deflater_bounds_wbtest.mbt`: "the deflater's arrays stay within the bounds gaato/deflate counts" |
| Encoder tokens (`src/encoder.mbt`, the deflater's `tokens`) | 64 KiB: one token for each literal or match that begins inside a block, which covers at most 16 KiB (a match may run past it without a token), so at most 16,384, in an array whose capacity doubles from 8 | Cannot overflow: a block is encoded once its 16 KiB are parsed | `scripts/flate_bounds/deflater_bounds_wbtest.mbt`: "the deflater's arrays stay within the bounds gaato/deflate counts" |
| Encoder output waiting (`src/encoder.mbt`, the deflater's `w.out`) | 32 KiB: the output of the input that waits, in at most two blocks that each cost no more than stored ones, and a flush's empty stored block, at most 16,660 bytes, in an array whose capacity doubles from 8 | `NeedMoreOutput`; no more input is taken until the caller has taken all of it | `src/bounds_wbtest.mbt`: "the encoder holds at most a block of input and its output"; `scripts/flate_bounds/deflater_bounds_wbtest.mbt`: "the deflater's arrays stay within the bounds gaato/deflate counts" |
| Encoder dictionary (`src/encoder.mbt`, `dictionary`) | A view of the preset dictionary's last 32 KiB, held by reference and not copied, to load the window again at `reset`; the deflater's ring holds the same bytes | Cannot overflow: a view of the last 32 KiB, whatever the dictionary's length | `src/bounds_wbtest.mbt`: "the encoder keeps the last 32 KiB of a dictionary, by reference" |
| Raw DEFLATE encoder memory (`@deflate.Encoder::memory_usage`) | The ring, the match finder, the tokens and the output above, and the symbol counts (316 entries of 4 bytes): 689,394 bytes, with a dictionary or without. The same from the first step to the last | Cannot overflow: each part is bounded by its own row | `src/bounds_wbtest.mbt`: "the encoder reports its bound after every step"; `scripts/flate_bounds/deflater_bounds_wbtest.mbt`: "the deflater's arrays stay within the bounds gaato/deflate counts" |
| zlib encoder header and trailer (`src/zlib/encoder.mbt`, `framing`) | 6 bytes: CMF, FLG and DICTID; then the 4 bytes of the Adler-32 | Cannot overflow | `src/zlib/bounds_wbtest.mbt`: "the encoder reports the raw encoder's bound after every step" |
| zlib encoder memory (`@zlib.Encoder::memory_usage`) | The raw DEFLATE encoder: 689,394 bytes, with a dictionary or without | Cannot overflow: one raw encoder | `src/zlib/bounds_wbtest.mbt`: "the encoder reports the raw encoder's bound after every step" |
| gzip encoder header (`src/gzip/encoder.mbt`, `header`) | The bytes of the header it writes, kept for `reset`: 10, or with a `Header` given, its extra field (at most 65,535 bytes, and 2 for its length), its name and its comment (each with a zero), copied once when the encoder is made. The trailer reuses `framing`: 8 bytes | A header that cannot be written (`Header::is_writable`) aborts when the encoder is made; the name and the comment are the caller's (see "Left to the caller") | `src/gzip/bounds_wbtest.mbt`: "the encoder reports the raw encoder's bound and its header after every step"; `src/gzip/encode_wbtest.mbt`: "panic an encoder given a header it cannot write aborts" |
| gzip encoder memory (`@gzip.Encoder::memory_usage`) | The raw DEFLATE encoder and the header's bytes: 689,394 bytes and 10, or with a `Header` given, the bytes it writes | Cannot overflow: each part is bounded by its own row | `src/gzip/bounds_wbtest.mbt`: "the encoder reports the raw encoder's bound and its header after every step" |
| One-shot output (`decompress` of each package, `max_output`) | `max_output` bytes when given; unlimited by default | `LimitExceeded({ resource: Output, needed: None, limit: max_output })` | `src/decode_wbtest.mbt`: "decompress honours max_output"; `src/zlib/decode_wbtest.mbt`: "decompress honours max_output"; `src/gzip/decode_wbtest.mbt`: "decompress honours max_output, over all members" |

## Fixed per decoder

| Structure | Size |
|---|---|
| The inflater's first-level Huffman tables (literal/length and distance) | 2 × 512 entries of 4 bytes: 4 KiB |
| The inflater's code lengths | 316 + 19 entries of 4 bytes: about 1.3 KiB |
| Checksum state: Adler-32 (zlib), CRC-32 and length (gzip), the header's CRC-32 | A few words |
| The fixed Huffman table, the CRC-32 table | 2 KiB and 1 KiB, shared by all decoders |

## Fixed per encoder

| Structure | Size |
|---|---|
| The deflater's bit writer, level settings and positions | A few words |
| Checksum state: Adler-32 (zlib), CRC-32 and length (gzip) | A few words |
| Per block, while it is encoded: the code lengths and codes of its Huffman codes, and on native and Wasm a scratch chunk for its tokens | A few KiB (the chunk is 6,152 bytes), allocated for the block and dropped once it is written |

## Left to the caller

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| Total output of a stream | The stream | `step` hands it out in slices; the caller decides what to keep |
| Input chunks | What the caller passes | `step` keeps no reference to them after it returns; what it needs it copies |
| A preset dictionary's bytes | The dictionary the caller gives the raw DEFLATE or zlib `Decoder` or `Encoder` | The decoder or the encoder keeps a view of its last 32 KiB, which keeps the whole `Bytes` it belongs to alive as long as it. A caller whose dictionary is a slice of a larger buffer it wants freed passes a copy of the slice |
| A gzip `Header`'s name and comment | What the caller gives `@gzip.Encoder` | The encoder writes them as they are, so it keeps a copy of them in the header's bytes for the stream |
| A gzip stream's members | The stream | Each is decoded and checked in turn; nothing of an earlier member is kept but the last header |
| `decompress` output | The stream | It returns the whole output; pass `max_output`, or use `Decoder` |
| `compress` output | The input | It returns the whole stream, at most 6 bytes per 16 KiB block more than the input (and the zlib or gzip framing); use `Encoder` to hand it out in slices |
