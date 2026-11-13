# Resource bounds

What a decoder and an encoder hold, and what keeps each structure from
growing without limit. The rule: **every structure that grows with the input is listed here
with its bound**. A new one needs a row before it ships.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests. A test counts only if it drives the structure to its limit, or checks
the bound after every step over streams that push it. `scripts/bounds_check.mbtx`,
run by `scripts/gates.mbtx`, enforces the naming; whether a named test really
reaches the bound is checked in review. The other tables are prose.

Sizes a frame header declares are untrusted: they are read in 64 bits and
checked against the limits before anything is allocated from them.

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|
| Window (`src/decoder.mbt`, `ring`) | At most the frame's `Window_Size`, which must be at most `1 << max_window_bits` (27 by default: 128 MiB; clamped to 10..30, so 1 GiB at most). A single-segment frame's window is its content size. Allocated from 1 KiB, doubling only as output needs it, so a frame that declares a large window but decodes little holds little. Released at the next frame when it is larger than that frame's window | `LimitExceeded({ resource: Memory, needed: Some(Window_Size), limit: 1 << max_window_bits })`, before anything is allocated | `src/bounds_wbtest.mbt`: "the window is at most Window_Size and grows only with output", "output slices, the window and the block buffers stay within their bounds"; `src/crafted_wbtest.mbt`: "windows are refused before anything is allocated"; `src/decode_wbtest.mbt`: "max_window_bits refuses larger windows and is clamped" |
| Output slice (`Decoder::step`, `Decoder::step_into`) | At most the caller's buffer per step, down to 1 byte; the rest waits in the window | `NeedMoreOutput` | `src/bounds_wbtest.mbt`: "output slices, the window and the block buffers stay within their bounds"; `src/decode_wbtest.mbt`: "any fixed input split and output size give the same output" |
| Pending output (`src/decoder.mbt`, `pending`) | At most the window. A compressed block is decoded only once nothing is pending, so it never overwrites bytes not handed out; raw and RLE blocks write only as far as the window has room | `NeedMoreOutput`; no input is taken until the caller has taken the output | `src/bounds_wbtest.mbt`: "a compressed block waits until earlier output is handed out" |
| Header bytes (`src/decoder.mbt`, `hdr`) | 14 bytes, the longest frame header. Every other input byte is copied to the window or the block buffer, or skipped | Cannot overflow | `src/bounds_wbtest.mbt`: "output slices, the window and the block buffers stay within their bounds"; `src/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| Compressed block (`src/decoder.mbt`, `block`) | `Block_Maximum_Size`: min(`Window_Size`, 128 KiB). A larger block is refused at its header, before its bytes are taken | `Corrupt` | `src/crafted_wbtest.mbt`: "block headers: the reserved type and the block limit"; `src/bounds_wbtest.mbt`: "output slices, the window and the block buffers stay within their bounds" |
| Literals (`src/decoder.mbt`, `literals`) | `Block_Maximum_Size`; a literals section declaring more is refused before it is decoded | `Corrupt` | `src/crafted_wbtest.mbt`: "literals sections cut short or out of range"; `src/bounds_wbtest.mbt`: "output slices, the window and the block buffers stay within their bounds" |
| Block output | `Block_Maximum_Size` per block, checked before each literal copy and match | `Corrupt` | `src/crafted_wbtest.mbt`: "sequences: offset codes, offsets and the block limit", "block headers: the reserved type and the block limit" |
| Frame output against its content size | `Frame_Content_Size` when the header declares one, checked after every block | `Corrupt` | `src/crafted_wbtest.mbt`: "content sizes: every field size, and frames that disagree with theirs" |
| Skippable frames | Skipped by a counter (up to 2^32 - 1 bytes); nothing is kept | Cannot overflow | `src/crafted_wbtest.mbt`: "skippable frames are skipped without being kept" |
| Reported memory (`Decoder::memory_usage`) | The window, the compressed block and the literals buffer: at most `(1 << max_window_bits) + 2 * 128 KiB`. The fixed tables below are not counted. It drops when the window is released for a frame that needs a smaller one, and to 0 at `reset` | Cannot overflow: each part is bounded by its own row | `src/bounds_wbtest.mbt`: "memory_usage stays within the window limit and two blocks", "memory_usage drops when a frame needs a smaller window" |
| Huffman weights (`src/huffman.mbt`, `weights`) | 255 decoded weights, as RFC 8878 allows | `Corrupt` | `src/crafted_wbtest.mbt`: "Huffman tree descriptions" |
| One-shot output (`decompress`, `max_output`) | `max_output` bytes when given; unlimited by default | `LimitExceeded({ resource: Output, needed: None, limit: max_output })` | `src/decode_wbtest.mbt`: "decompress honours max_output" |
| Encoder input buffer (`src/encoder.mbt`, `data`) | One block not encoded yet: Block_Maximum_Size, min(window, 128 KiB), and for a single-segment frame no more than its content size. Allocated from 1 KiB, doubling only as input arrives; released at `reset` | Cannot overflow: a step takes no more input than fills a block, and a full block is encoded before more is taken | `src/bounds_wbtest.mbt`: "the encoder's input buffer is at most a block, and grows only with input" |
| Encoder output waiting (`src/encoder.mbt`, `writer`, a `BitPacker` of `src/internal/bits`) | One block (3 + 128 KiB: a compressed block is chosen only when smaller than the raw one), with the magic number and the frame header (at most 14 bytes) before the first and the checksum (4) after the last: at most 131,093 bytes. The buffer doubles as it grows, so it may be up to twice that and 5 bytes | `NeedMoreOutput`; no input is taken and no block encoded until the caller has taken it all | `src/bounds_wbtest.mbt`: "the encoder's waiting output is at most a block and the frame's header and checksum" |
| Huffman coder's stream buffers (`src/internal/huffenc`, `packer` and `copy`) | Four literal streams, written only for a block they make smaller than raw: less than 128 KiB. The writer doubles as it grows (up to twice that and 5 bytes); the copy is exactly the largest so far | Cannot overflow: bounded by the block | `src/bounds_wbtest.mbt`: "the encoder's memory_usage stays within its bound after every step" |
| Encoder memory (`Encoder::memory_usage`) | Everything the encoder allocates: the input buffer, the waiting output and the Huffman coder's buffers above, and the fixed tables below: at most 131,072 + 2 * 131,098 + 2 * 131,077 + 131,072 + 8,036 = 794,530 bytes, whatever the level | Cannot overflow: each part is bounded by its own row | `src/bounds_wbtest.mbt`: "the encoder's memory_usage stays within its bound after every step", "the encoder's fixed tables and its memory bound" |
| Encoded size | A block is the smallest of raw, RLE and compressed, so a frame is at most its input, 3 bytes a block (an empty block for no input), the frame header and the checksum | Cannot overflow | `src/encode_wbtest.mbt`: "incompressible input costs 3 bytes a block and the frame's header and checksum" |
| Encoder input against its content size (`Encoder(content_size=..)`) | Exactly the content size given, which the frame header declares | `ChecksumMismatch`, as soon as a step's input would pass it (nothing of it taken) or at `Finish` short of it | `src/encode_wbtest.mbt`: "the input must match the content size given" |

## Fixed per decoder

| Structure | Size |
|---|---|
| FSE tables for literals lengths, match lengths and offsets | 512 + 512 + 256 states of 4 bytes: 5 KiB |
| Huffman table | 2,048 entries of 2 bytes: 4 KiB, and a 64-state weight table |
| Table scratch, XXH64 state, repeat offsets | About 2 KiB |
| The predefined tables | 160 states, shared by all decoders |

## Fixed per encoder

| Structure | Size |
|---|---|
| Literals writer (`src/block_writer.mbt`, `LiteralsWriter`) | 8,036 bytes, counted by `memory_usage`: the Huffman coder's code maker, code and weight tables, its 64-state FSE table for weights and the tree description, and two arrays of 256 byte counts |
| XXH64 state, flags | Under 100 bytes |

## Left to the caller

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| Total output of a stream | The stream | `step` hands it out in slices; the caller decides what to keep |
| Input chunks | What the caller passes | `step` keeps no reference to them after it returns; what it needs it copies, the encoder as well |
| `compress` output | The input | It returns the whole frame; use `Encoder` to stream |
| `decompress` output | The stream | It returns the whole output; pass `max_output`, or use `Decoder` |
