# Resource bounds

What a decoder and an encoder hold, and what keeps each structure from growing without
limit. The rule: **every structure that grows with the input is listed here
with its bound**. A new one needs a row before it ships.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests. A test counts only if it drives the structure to its limit, or checks
the bound after every step over streams that push it. `scripts/bounds_check.mbtx`,
run by `scripts/gates.mbtx`, enforces the naming; whether a named test really
reaches the bound is checked in review. The other tables are prose.

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|
| Sliding window (`src/decoder.mbt`, `ring`) | At most `1 << WBITS` bytes, so at most 16 MiB (WBITS 24); allocated from 1 KiB, doubling only as output needs it. A stream declaring a window (`(1 << WBITS) - 16` bytes, RFC 7932 section 9.1) over the one `max_window_bits` allows (24 by default, clamped to 10..24) is refused before anything is allocated; large-window streams (Shared Brotli, RFC 9841, not implemented) are refused | `LimitExceeded` with resource `Memory`, `needed` the stream's window and `limit` the largest allowed, both as `(1 << WBITS) - 16`; `Corrupt` for large-window streams | `src/bounds_wbtest.mbt`: "the window is at most 1 << WBITS and grows only with output", "output slices, the stash and the tables stay within their bounds"; `src/decode_wbtest.mbt`: "max_window_bits refuses larger windows and is clamped"; `src/crafted_wbtest.mbt`: "malformed streams raise the error the RFC calls for" |
| Output slice (`Decoder::step`, `Decoder::step_into`) | At most the caller's buffer per step, down to 1 byte; the rest waits in the window | `NeedMoreOutput` | `src/bounds_wbtest.mbt`: "output slices, the stash and the tables stay within their bounds"; `src/decode_wbtest.mbt`: "any fixed input split and output size give the same output" |
| Unfinished unit (`src/decoder.mbt`, `stash`) | 8 bytes: the longest unit, a command, is 63 bits. Every other input byte is decoded or reported unconsumed | Cannot overflow: a unit that has its bytes completes | `src/bounds_wbtest.mbt`: "output slices, the stash and the tables stay within their bounds"; `src/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| Prefix code tables (`src/huffman.mbt`, `Group`) | Per tree, alphabet + 376 entries of 2 bytes (the reference decoder's bound). Per meta-block at most 256 literal trees (632 entries each), 256 insert-and-copy trees (1,080) and 256 distance trees (896 at most): 1.3 MiB in the worst case, allocated for the trees a meta-block declares and kept for the next | Cannot overflow: RFC 7932 caps tree counts and alphabets | `src/bounds_wbtest.mbt`: "output slices, the stash and the tables stay within their bounds"; `src/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| One-shot output (`decompress`, `max_output`) | `max_output` bytes when given; unlimited by default | `LimitExceeded` with resource `Output`, no `needed`, and `max_output` as `limit` | `src/decode_wbtest.mbt`: "decompress honours max_output" |
| Encoder input buffer (`src/encoder.mbt`, `data`) | The window (`(1 << window_bits) - 16` bytes, at most 16 MiB) plus `max(1 << (window_bits - 2), 64 KiB)` of slack plus one 64 KiB meta-block not encoded yet: 5.06 MiB at the default `window_bits` 22, 20.06 MiB at 24. Allocated from 1 KiB, doubling only as input arrives; once full, it slides down by at least the slack, keeping the window | Cannot overflow: a step takes no more input than fills one meta-block, and encodes it before taking more | `src/bounds_wbtest.mbt`: "the encoder's input buffer grows only with input, then slides" |
| Encoder output waiting (`src/encoder.mbt`, `writer`) | One meta-block's output: at most its 64 KiB of input and 64 bytes. A compressed meta-block that grows past the size of an uncompressed one is stopped and written uncompressed | `NeedMoreOutput`; no input is taken until the caller has taken it all | `src/bounds_wbtest.mbt`: "the encoder's waiting output is at most a meta-block" |
| Decoder memory (`Decoder::memory_usage`) | The window and the prefix code tables above, the buffers sized by the stream: at most `(1 << max_window_bits) + 1,343,596` bytes. The tables are 256 trees of each category plus the block type, block count, context map and code length codes, at 2 bytes an entry; `reset` releases the window and keeps the tables | Cannot overflow: the window and the tables are bounded above | `src/bounds_wbtest.mbt`: "memory_usage stays within its bound after every step", "output slices, the stash and the tables stay within their bounds"; `src/fuzz_wbtest.mbt`: "corrupted streams raise errors or decode, within bounds, never abort" |
| Encoder memory (`Encoder::memory_usage`) | The input buffer and the waiting output above, the buffers that grow with the stream: at most `(1 << window_bits) - 16 + max(1 << (window_bits - 2), 64 KiB) + 64 KiB + 131,200` bytes (the output buffer doubles, so it holds up to twice one meta-block's output): 5,439,600 bytes at the default `window_bits` 22, 21,168,240 at 24. The hash table and the commands are fixed per encoder and not counted; `reset` releases the input buffer | Cannot overflow: the input buffer and the waiting output are bounded above | `src/bounds_wbtest.mbt`: "memory_usage stays within its bound after every step", "the encoder's input buffer grows only with input, then slides" |
| Encoder commands (`src/meta_block_writer.mbt`, `MetaBlock`) | 16,385 per meta-block: one per 4-byte match in 64 KiB, and one for the literals at the end. Five arrays of that, allocated once | Cannot overflow: matches are at least 4 bytes | `src/bounds_wbtest.mbt`: "the encoder's input buffer grows only with input, then slides", "the encoder's waiting output is at most a meta-block" |

## Fixed per decoder

| Structure | Size |
|---|---|
| Context maps | 16 KiB (literals) + 1 KiB (distances) |
| Code length scratch, table builder scratch, block type state | About 8 KiB |
| Transformed dictionary word | 37 bytes |
| The static dictionary and transform tables | 122,784 + about 1 KiB, shared by all decoders |

## Fixed per encoder

| Structure | Size |
|---|---|
| LZ77 hash table (`src/internal/lz77`) | `4 << min(window_bits, 15)` positions: 128 Ki entries, 512 KiB at 4 bytes each |
| Meta-block commands and their codes | Five arrays of 16,385 (320 KiB), plus histograms and codes of the 256-, 704- and 64-symbol alphabets |
| Distance ring, code length scratch | A few KiB |

## Left to the caller

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| Total output of a stream | The stream | `step` hands it out in slices; the caller decides what to keep |
| Input chunks | What the caller passes | `step` keeps no reference to them after it returns; the encoder copies what it takes |
| `decompress` output | The stream | It returns the whole output; pass `max_output`, or use `Decoder` |
