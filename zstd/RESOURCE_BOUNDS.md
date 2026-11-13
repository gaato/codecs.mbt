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
| Encoder match window and hash (`src/internal/match`) | window + one block bytes; fast adds `4 * 2^hashLog` hash bytes and 12 repeat bytes, double-fast adds `4 * (2^hashLog + 2^chainLog)` hash bytes. Largest selected row: windowLog 21, hashLog 18, chainLog 18, totaling 4,325,376 bytes. Positions rebase after each block; only bytes retained in this frame are eligible, at distance at most window | Cannot overflow; old history is discarded and both tables' positions invalidated | `src/internal/match/fast_wbtest.mbt`: "fast history wraps within the window and resets before another frame"; `src/internal/match/dfast_wbtest.mbt`: "dfast history wraps within the window and resets before another frame", "dfast permits the exact window distance and refuses older hash candidates"; `src/bounds_wbtest.mbt`: "double-fast memory reaches both tables and the full window plus a block", "the encoder's memory_usage stays within its bound after every step" |
| Encoder sequences and literals (`src/internal/seqenc/Block`) | At most floor(128 KiB / 3) sequences, three 4-byte arrays, one block of gathered literals, and 12 repeat bytes: 655,364 bytes. Fast actually emits matches of at least 4 bytes; the bound also admits RFC minimum length 3 | Cannot overflow: array growth is capped at the sequence limit | `src/internal/seqenc/block_wbtest.mbt`: "sequence storage reaches its RFC block capacity and keeps bounded arrays"; `src/bounds_wbtest.mbt`: "the encoder's memory_usage stays within its bound after every step" |
| Encoder sequence scratch (`sequence_bits`, `sequence_copy`) | Bitstream below 512 KiB: at most 43,690 sequences times (9 + 9 + 8 state bits + 16 + 16 + 31 extra bits), plus three descriptions below 512 bytes, states, header and sentinel. Packer capacity below `2 * (512 KiB + 5)`. The copy is allocated only for an accepted compressed block, smaller than 128 KiB | Candidate too large is discarded for raw | `src/bounds_wbtest.mbt`: "the encoder's memory_usage stays within its bound after every step"; `src/sequence_encode_wbtest.mbt`: "sequence sections: every mode, large counts, long extras and near-window offsets" |
| Entropy scratch (`seqenc/Stream`, `huffenc`) | Three FSE description packers and two Huffman weight packers, each with at most 512 bytes of payload (at most 53 normalized counts, or 255 weights with codes at most 6 bits). Each retains at most `2 * (512 + 5)` bytes. Literal streams go directly to the output, with no private stream copy | Cannot overflow: fixed alphabets and weight count | `src/bounds_wbtest.mbt`: "the encoder's memory_usage stays within its bound after every step", "the encoder's fixed tables and its memory bound" |
| Encoder memory (`Encoder::memory_usage`) | All retained arrays: input, waiting output, match window and hash, sequence arrays and scratch, and fixed entropy tables. `encoder_memory_bound(params)` derives the bound from each selected row; the maximum is **6,582,176 bytes**, at the large-input level-four double-fast row. Later strategies temporarily use no larger row. Includes capacity retained from larger prior blocks and across reset | Cannot overflow: each part is bounded by its own row | `src/bounds_wbtest.mbt`: "the encoder's memory_usage stays within its bound after every step", "the encoder's fixed tables and its memory bound", "double-fast memory reaches both tables and the full window plus a block" |
| Encoded size | A block is the smallest of raw, RLE and compressed, so a frame is at most its input, 3 bytes a block (an empty block for no input), the frame header and the checksum | Cannot overflow | `src/encode_wbtest.mbt`: "incompressible input costs 3 bytes a block and the frame's header and checksum" |
| Encoder input against its content size (`Encoder(content_size=..)`) | Exactly the content size given, which the frame header declares | `ChecksumMismatch`, once the input passes it (the bytes up to it are taken as with `Continue` and the output they decide is handed out first, so the output before the error does not depend on the splits) or at `Finish` short of it | `src/encode_wbtest.mbt`: "the input must match the content size given", "input past the content size raises after the same output, however it is split" |

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
| Literals writer (`src/block_writer.mbt`, `LiteralsWriter`) | 14,024 bytes initially, counted by `memory_usage`: candidate and previous Huffman encoders, and two arrays of 256 byte counts. Only a committed compressed literals section replaces the previous tree |
| Sequence writer (`src/internal/seqenc`) | LL/ML tables up to 512 states, OF up to 256, their counts, candidate and committed normalized distributions, and repeat history. Initial 9,316 bytes; description packer capacities are counted separately above |
| XXH64 state, flags | Under 100 bytes |

## Encoder bound derivation

`src/bounds_wbtest.mbt` computes the sum from the effective row (including
the temporary fallback), then checks it after every step. The largest
row has windowLog 21, hashLog 18, chainLog 18. Its terms in bytes are:

| Structure | Bytes |
|---|---:|
| Input | 131,072 |
| Waiting output, `2 * (131093 + 5)` | 262,196 |
| Fixed literals writer | 14,024 |
| Five entropy description packers, `5 * 2 * (512 + 5)` | 5,170 |
| Match window + block + two position tables, `2^21 + 131072 + 4 * (2^18 + 2^18)` | 4,325,376 |
| Sequence arrays, literals and repeats, `12 * floor(131072 / 3) + 131072 + 12` | 655,364 |
| Fixed sequence writer | 9,316 |
| Sequence bitstream packer, `2 * (2^19 + 5)` | 1,048,586 |
| Accepted sequence copy | 131,072 |
| **Total** | **6,582,176** |

The full-window test reaches the 4,325,376-byte matcher allocation.
All twelve levels and the four size classes are checked against the
maximum. Known-size adjustment reduces hashLog and chainLog using the
shrunken window before its frame minimum is restored. The tests in
`src/params_wbtest.mbt` pin adjusted reference rows and verify that window,
hash and chain logs only shrink, including tiny inputs and tree cycle
logs. This does not change the maximum above. Sequence bitstream capacity
retains the shared BitPacker's
doubling allowance; exact reservation is a possible later reduction.

## Left to the caller

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| Total output of a stream | The stream | `step` hands it out in slices; the caller decides what to keep |
| Input chunks | What the caller passes | `step` keeps no reference to them after it returns; what it needs it copies, the encoder as well |
| `compress` output | The input | It returns the whole frame; use `Encoder` to stream |
| `decompress` output | The stream | It returns the whole output; pass `max_output`, or use `Decoder` |
