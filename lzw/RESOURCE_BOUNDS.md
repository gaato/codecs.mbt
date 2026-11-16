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
| The decoder's table (`src/decoder.mbt`, `prefix`, `suffix`, `first`, `length`) | `1 << max_bits` codes of 6 bytes: 4,096 for GIF, TIFF and PDF, `1 << max_bits` for .Z, allocated once the format (for .Z, its header) gives the width. A full table defines no more codes | A .Z header wider than the decoder's `max_bits`: `LimitExceeded` with resource `Memory`, `needed` and `limit` the tables' bytes, before anything is allocated. A full table: codes stay at the widest width, as GIF89a allows | `src/lzw_wbtest.mbt`: "streams that break the format are refused", "a full GIF table without a clear keeps its codes, as GIF89a allows" |
| A string not handed out yet (`src/decoder.mbt`, `string`) | The longest string the table holds, at most its length, and a byte | `NeedMoreOutput` until it is all handed out | `src/lzw_wbtest.mbt`: "streams round-trip in every format, however split, within the bounds" |
| Decoder memory (`Decoder::memory_usage`) | The table and the string: at most `7 << max_bits` and 1 bytes, 28,673 for GIF, TIFF and PDF, 458,753 for .Z of 16 bits, what `decoder_memory_bound(format)` returns | Cannot overflow: the width is bounded | `src/lzw_wbtest.mbt`: "streams round-trip in every format, however split, within the bounds" |
| Encoder memory (`Encoder::memory_usage`) | The same from the first step to the last: a hash table of twice the codes, 6 bytes a slot, and 256 bytes of output, 49,408 for GIF, TIFF and PDF, 786,688 for .Z of 16 bits, what `encoder_memory_bound(format)` returns | Cannot overflow: allocated with the encoder | `src/lzw_wbtest.mbt`: "reset, the end of a stream, errors that stay, and memory" |
| Output waiting in the encoder (`src/encoder.mbt`, `out`) | 256 bytes: a step takes 64 bytes of input at a time, each a code of at most 16 bits, with a clear and .Z's padding | `NeedMoreOutput`; no input is taken until it is all handed out | `src/lzw_wbtest.mbt`: "streams round-trip in every format, however split, within the bounds" |
| Encoded size (`compress`, `Encoder`) | Every byte a code of the widest width, with the clear and end codes, a clear for every 3,000 bytes, and for .Z its header and seven codes of padding at each of its widths after each clear, what `compress_bound(n, format)` returns | Cannot overflow: each code is bounded | `src/lzw_wbtest.mbt`: "streams round-trip in every format, however split, within the bounds" |
| One-shot output (`decompress`, `max_output`) | `max_output` bytes when given; unlimited by default | `LimitExceeded` with resource `Output`, no `needed`, and `max_output` as `limit` | `src/lzw_wbtest.mbt`: ".Z padding split anywhere or cut short, max_output, and Continue" |

## Left to the caller

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| Output | The stream | A code of 12 bits can stand for a string of up to 4,096 bytes (16 bits for 65,536 in .Z), so a small stream may decode to a large output; `max_output` bounds the one-shot functions, and a streaming caller its own buffer |
