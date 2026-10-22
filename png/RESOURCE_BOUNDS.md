# Resource bounds

What the PNG decoder holds, and what keeps each structure from growing
without limit. The rule: **every structure that grows with the input is
listed here with its bound**. A new one needs a row before it ships.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests. A test counts only if it drives the structure to its limit, or checks
the bound after every step over images that push it.
`scripts/bounds_check.mbtx`, run by `scripts/gates.mbtx`, enforces the
naming; whether a named test really reaches the bound is checked in review.

The decoder holds two rows and a zlib decoder, whatever the image's height:
rows are handed out as they are decoded, and an interlaced image comes out
pass by pass, so nothing holds the image. Chunk data passes through, into
IHDR's and PLTE's fixed fields, into the zlib decoder, or only into the CRC
of a chunk that is skipped. Sizes count 1 byte for a `Byte`.

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|
| Rows (`src/decoder.mbt`, `prev`, `cur`) | Two of 1 + the bytes of a row of the image's full width (ceil(width × bits a pixel / 8), computed in 64 bits by `@rules.row_bytes`), the filter type byte first: at most `max_row_bytes` bytes of row each, 8,000,000 by default and at most 1,000,000,000. Allocated once, at the step after `Header`, before any image data; a pass of an interlaced image uses the start of them | `LimitExceeded({ resource: Memory, needed: Some(row bytes), limit: max_row_bytes })` at the step after `Header`, before anything is allocated | `src/bounds_wbtest.mbt`: "max_row_bytes: a longer row is refused after Header, before anything is allocated", "memory: the zlib decoder, the palette, and two rows from the step after Header"; `src/internal/rules/rules_test.mbt`: "row_bytes: packed rows, in 64 bits, against the limit" |
| zlib decoder (`src/decoder.mbt`, `inflater`) | One `@zlib.Decoder` for the decoder's life: 46,592 bytes (see `deflate/RESOURCE_BOUNDS.md`), reset with the decoder | Cannot overflow: one decoder | `src/bounds_wbtest.mbt`: "memory: the zlib decoder, the palette, and two rows from the step after Header" |
| Palette (`src/decoder.mbt`, `plte`) | 768 bytes, 256 entries of three, allocated when the decoder is made | A PLTE of more than 768 bytes, or of a length that is not a multiple of 3, is `Corrupt` in an indexed-color image and left out in others | `src/decode_wbtest.mbt`: "refusals: PLTE", "a truecolor image's PLTE of a wrong length is left out" |
| Units held back (`src/decoder.mbt`, `held`, `ihdr`) | 8 bytes: the signature, a chunk's length and type, or its CRC, one at a time; and IHDR's 13 bytes. Every other input byte is used as it comes | Cannot overflow: an IHDR of another length is `Corrupt` | `src/decode_wbtest.mbt`: "the image data in IDAT chunks of every size, split anyhow", "refusals: the signature, IHDR and the chunks' frame" |
| Output slice (`Decoder::step`) | Whole rows, as many of one pass as the caller's slice holds; a slice shorter than `room_needed` takes nothing | `NeedMoreOutput` | `src/bounds_wbtest.mbt`: "output slices: whole rows, at most the slice, whatever it is given"; `src/decode_wbtest.mbt`: "the answers: Header, Frame, the rows of each pass, FrameEnd, Done" |
| Decoder memory (`Decoder::memory_usage`) | The zlib decoder, the palette and the two rows above: 47,360 bytes before the step after `Header`, then 47,360 + 2 × (1 + row bytes), the same to the end of the image; 47,360 again after `reset` | Cannot overflow: each part is bounded by its own row | `src/bounds_wbtest.mbt`: "memory stays what the formula says after every step, for every format and split", "memory: the zlib decoder, the palette, and two rows from the step after Header"; `src/fuzz_wbtest.mbt`: "corrupted images raise errors or decode, the same under every split, within bounds" |
