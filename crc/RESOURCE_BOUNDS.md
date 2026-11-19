# Resource bounds

What a `Crc` and a `Digest` hold. Nothing grows with the data: a CRC is
computed over the caller's bytes as they are given, and keeps none of them.

**Every row of "Enforced limits" names a test that checks the bound**, in its
Tests column: a backticked file path, then the quoted names of that file's
tests. `scripts/bounds_check.mbtx`, run by `scripts/gates.mbtx`, enforces the
naming; whether a named test really reaches the bound is checked in review.

## Enforced limits

| Structure | Bound | On overflow | Tests |
|---|---|---|---|
| A `Crc`'s table (`src/crc.mbt`, `table`) | 256 entries, up to 2 KiB of entry values. On Wasm and JS, a width of at most 32 stores 1 KiB of entry values after converting a temporary 2 KiB table at construction. | Cannot overflow: fixed size | `src/crc_wbtest.mbt`: "a Crc holds a table of 256 entries, and the fast ones' tables are fixed" |
| A `Digest` (`src/crc.mbt`) | The `Crc` it was made from and one 64-bit value | Cannot overflow: fixed size | `src/crc_wbtest.mbt`: "a digest gives the CRC of what it was written, in pieces" |
| `combine`'s work | `width` multiplications of `width` steps for each bit of `len_b`, at most 64 × 64 × 64 steps; no allocation | Cannot overflow: the length is a 64-bit count | `src/crc_wbtest.mbt`: "combine's powers of x add their exponents, past 2^31 bytes" |

## Fixed per program

| Structure | Size |
|---|---|
| CRC-32's slice-by-8 tables (`src/internal/crc32`) | 9 KiB, computed at start-up |
| CRC-32C's slice-by-8 tables (`src/internal/crc32c`) | 9 KiB, computed at start-up |
| CRC-64/XZ's slice-by-8 tables (`src/fast.mbt`) | 18 KiB of 64-bit table values, plus 16 KiB of 32-bit table values on JS, computed at start-up |
| The catalogue (`src/catalogue.mbt`) | 112 entries of parameters and names |

## Left to the caller

| Structure | Grows with | Why it is not bounded here |
|---|---|---|
| The data | What the caller passes | `checksum` and `update` read it and keep no reference to it |
