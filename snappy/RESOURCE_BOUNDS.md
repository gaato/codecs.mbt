# Resource bounds

What the decoders and the encoders hold, and what keeps each structure from
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
| Raw output (`decompress_raw`, `src/raw.mbt`) | The length the stream declares, at most `max_output` (2^31 - 1 by default, what an array holds) and at most 22 times the bytes after it (a copy of 64 bytes takes 3, the most any element writes per byte), both checked before the output is allocated | `LimitExceeded` with resource `Output`, `needed` the declared length and `limit` the maximum; `Corrupt` for a length the bytes cannot make | `src/snappy_wbtest.mbt`: "raw streams that break the format are refused" |
| A framed chunk's body (`src/framing.mbt`, `body`) | 76,494 bytes, the checksum and the most a raw stream of 64 KiB takes, as the snap crate and golang/snappy hold; allocated at the first chunk that needs it. The format allows a compressed chunk of up to 2^24 - 1 bytes that decodes to 64 KiB, which no encoder writes. Skippable chunks are skipped as they arrive, none of them held | From its header, before any of its body is read: `LimitExceeded` with resource `Memory`, `needed` the chunk's length and `limit` 76,494, for a longer compressed chunk; `Corrupt` for an uncompressed one over 65,540 bytes, which the format refuses | `src/snappy_wbtest.mbt`: "framed streams that break the format are refused", "memory stays what the bounds say" |
| A framed chunk's decoded bytes (`src/framing.mbt`, `out`) | 65,536 bytes; a chunk whose raw stream declares more is refused before decoding | `Corrupt` | `src/snappy_wbtest.mbt`: "framed streams that break the format are refused", "memory stays what the bounds say" |
| Output slice (`Decoder::step`) | At most the caller's buffer per step, down to 1 byte; the rest of the chunk waits | `NeedMoreOutput` | `src/snappy_wbtest.mbt`: "framed streams round-trip however split, and flushes decode" |
| One-shot framed output (`decompress`, `max_output`) | `max_output` bytes when given; unlimited by default | `LimitExceeded` with resource `Output`, no `needed`, and `max_output` as `limit` | `src/snappy_wbtest.mbt`: "framed streams that break the format are refused" |
| Encoded size (`compress_raw`, `compress`, `Encoder`) | `32 + n + n / 6` bytes for a raw stream of `n` bytes, snappy's `MaxCompressedLength` (`raw_compress_bound(n)`); for a framed one, the 10-byte identifier and each chunk of up to 64 KiB with 8 bytes more, since a chunk that would grow is stored (`compress_bound(n)`), and 8 more for each `Flush` | Cannot overflow: each fragment is bounded. `compress_raw` and `compress` allocate the bound first, and abort for inputs whose bound passes 2^31 - 1 bytes (over 1,840,700,242 and 2,147,221,517 bytes) | `src/snappy_wbtest.mbt`: "raw streams round-trip and stay within the bound", "framed streams round-trip however split, and flushes decode" |
| Encoder memory (`Encoder::memory_usage`) | 251,302 bytes from the first step to the last, what `encoder_memory_bound()` returns: 64 KiB of input, a chunk's output with the identifier, the raw stream it is made from, and the 2^14-entry hash table | Cannot overflow: allocated with the encoder | `src/snappy_wbtest.mbt`: "memory stays what the bounds say" |
| Decoder memory (`Decoder::memory_usage`) | At most 142,034 bytes, what `decoder_memory_bound()` returns: the 4-byte chunk header, a chunk's body and its decoded bytes | Cannot overflow: the two buffers are bounded above | `src/snappy_wbtest.mbt`: "memory stays what the bounds say" |

## Left to the caller

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| Raw input and output | The whole stream | The raw format is whole: its length comes first, and a copy may reach back to the start of the output |
| Framed input | What the caller passes per step | The decoder reads it in place and keeps only a chunk |
