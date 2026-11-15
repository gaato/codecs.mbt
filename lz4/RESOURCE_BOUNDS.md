# Resource bounds

What the decoder and the encoder hold, and what keeps each structure from
growing without limit. The rule: **every structure that grows with the input
is listed here with its bound**. A new one needs a row before it ships.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests. A test counts only if it drives the structure to its limit, or checks
the bound after every step over streams that push it. `scripts/bounds_check.mbtx`,
run by `scripts/gates.mbtx`, enforces the naming; whether a named test really
reaches the bound is checked in review. The other tables are prose.

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|
| The window (`src/decoder.mbt`, `win`) | 256 KiB: the last 64 KiB of output (the most a match reaches back), the output not handed out yet, and room; allocated from 4 KiB, doubling as output needs it, then sliding down. A block is decoded into it as its bytes arrive, so no block, however large the frame's, is held whole | `NeedMoreOutput` while output waits; the window slides once it is handed out | `src/lz4_wbtest.mbt`: "memory stays within the bounds", "frames round-trip however split and flushed, within the bounds" |
| A block's output (`src/decoder.mbt`, `block_out`) | The frame's block size (64 KiB to 4 MiB, 8 MiB for a legacy frame), checked before each sequence's literals and match are written, and as a length grows by 255s, so that it cannot overflow | `Corrupt` | `src/lz4_wbtest.mbt`: "limits stop long lengths and long output" |
| A frame's output against its content size (`src/decoder.mbt`, `frame_out`) | The declared size, checked before each block's bytes are written | `ChecksumMismatch` (a length the stream declares that does not match it) once a block would pass it, and at the end mark when the frame holds less | `src/lz4_wbtest.mbt`: "content sizes and dictionaries are checked", "limits stop long lengths and long output" |
| A block's stored bytes (block header) | The frame's block size | `Corrupt`, from the header, before any of the block is read | `src/lz4_wbtest.mbt`: "frames that break the format are refused" |
| Skippable frames | None held: skipped as they arrive | Cannot overflow: nothing is kept | `src/lz4_wbtest.mbt`: "frames, skippable frames and legacy frames follow one another" |
| One-shot output (`decompress`, `max_output`; `decompress_block`, `max_output~`) | `max_output` bytes (none for `decompress` by default); a block's, checked as it decodes, before anything past it is written | `LimitExceeded` with resource `Output`, no `needed`, and `max_output` as `limit` | `src/lz4_wbtest.mbt`: "limits stop long lengths and long output", "blocks that break the format are refused" |
| Encoded size (`compress`, `Encoder`; `compress_block`) | `19 + n + 8 * ceil(n / block size) + 8` bytes for a frame of `n` bytes (`compress_bound(n, block_size~)`): a block is stored uncompressed rather than grow, so it takes its bytes, its size and its checksum; 8 more for each `Flush`. A block on its own takes at most `n + n / 255 + 16` (`block_compress_bound(n)`, lz4's `LZ4_COMPRESSBOUND`) | Cannot overflow: each block is bounded. `compress_block` aborts for inputs over lz4's 2,113,929,216 bytes | `src/lz4_wbtest.mbt`: "frames round-trip however split and flushed, within the bounds", "blocks round-trip, within the bound, with and without a dictionary" |
| Encoder memory (`Encoder::memory_usage`) | The same from the first step to the last: a block of input, the 64 KiB before it for linked blocks or a dictionary, the hash table and the dictionary's (2^13 entries of 4 bytes each), and a block's output with the header and footer: 229,411 bytes at the defaults, at most 262,179 for 64 KiB blocks and 8,519,715 for 4 MiB ones, what `encoder_memory_bound(block_size~)` returns | Cannot overflow: allocated with the encoder | `src/lz4_wbtest.mbt`: "memory stays within the bounds" |
| Decoder memory (`Decoder::memory_usage`) | The window, at most 262,144 bytes, what `decoder_memory_bound()` returns | Cannot overflow: the window is bounded above | `src/lz4_wbtest.mbt`: "memory stays within the bounds" |

## Left to the caller

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| The dictionary | What the caller passes | Kept by reference: its last 64 KiB are copied into the window at the start of a frame, or of each independent block, and the encoder copies them once |
| A block on its own (`compress_block`, `decompress_block`) | The block | The block format has no framing: the input is whole, and its output is what `max_output` allows |
