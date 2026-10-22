# Proofs

`moon prove` (Why3 and an SMT solver) checks the functions below against the
W3C PNG Specification (Third Edition): the code that runs, not a model of
it. Each proof holds for the inputs its precondition allows, which the
callers guarantee (a pixel's bytes are 1 to 8, chunk type bytes are bytes,
IHDR's width has been checked).

The proved functions are the cores the decoder and the conversions call:
integer functions without tables, arrays other than `FixedArray`, or
`Result`, which the prover does not model. The functions around them read
the tables, raise the errors and write the messages; the tests check them.

Run the proofs with `moon run scripts/prove.mbtx` from the repository root
(Z3 4.16.0 on PATH), and with `-- --solver cvc5` for the second solver (CVC5
1.4.2). `moon run scripts/proof_check.mbtx -- png` checks this ledger
against the code.

## What is trusted

- The bridges below: `moon prove` takes their contracts as given. Each is a
  bit operation or a byte conversion the prover does not model, and its tests
  check it over its precondition's whole domain.
- The solvers, Why3 and moonc's translation to Why3. Negative controls
  (`parts/proof_controls`) check that each solver refuses false claims.
- All four packages are proved with the unbounded prelude, where integers do
  not overflow in the proof. Where the code multiplies or adds values that
  come from the input (`row_size`, `frame_inside`), a `proof_assert` states
  that the result fits its type, and the solvers prove it from the
  preconditions; the other values are bytes and small counts.

## Proved

| Function | Package | Property | Prelude | Bridges | Solvers |
| --- | --- | --- | --- | --- | --- |
| `paeth` | `src/internal/filter` | The Paeth predictor of 9.4, as its pseudo-code writes it (ties to a, then b), for bytes a, b and c; the result is one of them, so a byte | unbounded | none | Z3, CVC5 |
| `unfilter` | `src/internal/filter` | Every index the reversal of the five filter types (9.2 to 9.4) reads or writes, through `sub`, `up`, `average` and `paeth_row`, is from 1 up to and below both rows' lengths, whatever `len` says; the left neighbour is read only `pixel` bytes after the first, so from 1 on; Average's halved sum and Paeth's predictor are bytes; and the answer is whether the type is 0 to 4 | unbounded | `shr`, `byte_add`, `byte_of` | Z3, CVC5 |
| `packed_sample` | `src/internal/convert` | Sample `k` of a byte packed at 1, 2 or 4 bits (7.2) is the byte's bits from 8 − depth × (k + 1) up, and below 2^depth, so every palette index it gives is inside the converter's table of 256 | unbounded | `shr`, `low_bits` | Z3, CVC5 |
| `widen` | `src/internal/convert` | A sample of 1, 2, 4 or 8 bits on 8 bits is exactly v × 255 / (2^depth − 1), from 0 to 255: repeating its bits (12.4) | unbounded | none | Z3, CVC5 |
| `narrow` | `src/internal/convert` | A 16-bit sample on 8 bits is the nearest: 257 × r − v is from −128 to 128, which only round(v × 255 / 65535) meets | unbounded | none | Z3, CVC5 |
| `property_bit` | `src/internal/rules` | A chunk type byte's property bit (5.4) is its bit 5 | unbounded | `shr`, `low_bits` | Z3, CVC5 |
| `is_letter` | `src/internal/rules` | A chunk type byte is a letter (5.3), A to Z or a to z, exactly when, with bit 5 cleared, it is A to Z | unbounded | none | Z3, CVC5 |
| `lattice_count` | `src/internal/rules` | The columns or rows of an Adam7 pass (8.2): the count of start + i × step below the size, for the starts and steps of Adam7, at every size an image can have | unbounded | none | Z3, CVC5 |
| `row_size` | `src/internal/sizes` | A row's bytes are ceil(width × bits / 8) for every pixel size of table 11 and every width up to 2^31 − 1, or −1 exactly when that is over the limit, computed without a product that overflows 32 bits | unbounded | none | Z3, CVC5 |
| `frame_inside` | `src/internal/sizes` | An fcTL's rectangle is inside the image (11.3.6.2) exactly when x + width ≤ the image's width and y + height ≤ its height, for 32-bit fields, the sums in 64 bits below 2^33 | unbounded | none | Z3, CVC5 |

## Tested instead

These have finite domains, and their tests go over all of them, against the
specification's tables written out apart from the code:

- Adam7's 8 x 8 block, every position in exactly one pass: "Adam7,
  exhaustively: every position of the 8 x 8 block is in exactly one pass, as
  8.2 draws it" (`src/internal/rules/rules_test.mbt`).
- The color types and bit depths of table 12, and IHDR's other fields:
  "check_header, exhaustively: every color type and bit depth against table
  12, and the other fields of table 11" (`src/internal/rules/rules_test.mbt`).
- Where each chunk may come (table 7): "place, exhaustively: every ancillary
  chunk, at every position, once and twice, for every color type, against
  table 7" and "place: the critical chunks"
  (`src/internal/rules/rules_test.mbt`).

## Not proved

- The decoder's state machine, the reading of chunks and APNG's frames, the
  conversions of whole rows and `scatter`: their loops go through tables,
  `ArrayView` and `MutArrayView`, which the prover does not model. The
  conformance suite runs them over PngSuite and the APNG test images against
  pypng, typst and the png crate.
- CRC-32 (`src/internal/crc32`) is arithmetic that relies on wrapping, and
  zlib is `gaato/deflate`'s.

## Trusted bridges

| Bridge | Package | Claim | Backing test |
| --- | --- | --- | --- |
| `shr` | `src/internal/proof_bits` | `x >> k` is `x / 2^k` for `x >= 0`, `0 <= k <= 30` | `src/internal/proof_bits/shifts_test.mbt`: "shr and low_bits are division and remainder by 2^k" |
| `low_bits` | `src/internal/proof_bits` | `x & (2^k - 1)` is `x % 2^k` for `x >= 0`, `0 <= k <= 30` | `src/internal/proof_bits/shifts_test.mbt`: "shr and low_bits are division and remainder by 2^k" |
| `shl` | `src/internal/proof_bits` | `x << k` is `x * 2^k` for `x >= 0`, `0 <= k <= 30`, while that fits an `Int`; copied with the others, used by no proof here | `src/internal/proof_bits/shifts_test.mbt`: "shl is multiplication by 2^k while the product fits" |
| `byte_add` | `src/internal/filter` | The sum of two bytes, wrapped to a byte, is `(a + b) % 256`: the prover has no `Byte::add` | `src/internal/filter/bridges_wbtest.mbt`: "byte_add wraps modulo 256, for every pair of bytes" |
| `byte_of` | `src/internal/filter` | `x.to_byte().to_int()` is `x` for `0 <= x <= 255`: the prover has no `Int::to_byte` | `src/internal/filter/bridges_wbtest.mbt`: "byte_of is to_byte, for every byte" |

`src/internal/proof_bits` is a copy of `parts/proof_bits`, where lemmas check
that its table of powers of two doubles at every step.

Bridge budget: 5
