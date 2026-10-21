# Proofs

`moon prove` (Why3 and an SMT solver) checks the functions below against
RFC 8878: the code that runs, not a model of it. Each proof holds for the
inputs its precondition allows, which the callers guarantee (header bytes are
bytes, a block header is 24 bits).

Most of them are the core of a function of `src/internal/header` that returns
a `Result`, which the prover does not model: the public function masks its
inputs to the bytes they are and turns the core's answer into the `Result`
and its message. The tests of `src/internal/header` check the public
functions, exhaustively or over grids, against references written from the
RFC.

Run the proofs with `moon run scripts/prove.mbtx` from the repository root
(Z3 4.16.0 on PATH), and with `-- --solver cvc5` for the second solver (CVC5
1.4.2). `moon run scripts/proof_check.mbtx -- zstd` checks this ledger
against the code.

## What is trusted

- The bridges below: `moon prove` takes their contracts as given. Each is a
  bit operation or a conversion the prover does not model, and its tests check
  it over its precondition's domain.
- The solvers, Why3 and moonc's translation to Why3. Negative controls
  (`parts/proof_controls`) check that each solver refuses false claims.
- With the unbounded prelude, integers do not overflow in the proof; the
  preconditions bound every value well below 2^31. `src/internal/frame` is
  proved with the machine-integer prelude instead, where every `+` and `*`
  is proved not to overflow.

## Proved

| Function | Package | Property | Prelude | Bridges | Solvers |
| --- | --- | --- | --- | --- | --- |
| `literals_header_of` | `src/internal/header` | Core of `decode_literals_header`: block type, size format, header length, Regenerated_Size and Compressed_Size are the fields of section 3.1.1.3.1.1, read from the bytes as one little-endian number; refused, with the reason, exactly by the decoder's checks in order (header past the block, more literals than Block_Maximum_Size, four streams with fewer than 6 literals as erratum 7297 requires, section past the block); an accepted header's fields are in range, and with four streams the last stream's share, `regenerated - 3 * ceil(regenerated / 4)`, is not negative | unbounded | `shr`, `low_bits`, `shl` | Z3, CVC5 |
| `fourth_stream_size` | `src/internal/header` | Core of `stream_sizes` (section 3.1.1.3.1.6): the jump table and four streams fit in `total`, at least 10 bytes, exactly when the fourth stream has a byte; the four sizes and the table add up to `total` | unbounded | none | Z3, CVC5 |
| `block_header_of` | `src/internal/header` | Core of `parse_block_header` (section 3.1.1.2): Last_Block is bit 0, Block_Type bits 1 and 2, Block_Size the rest (below 2^21); refused exactly for the reserved type 3 | unbounded | `shr`, `low_bits` | Z3, CVC5 |
| `block_refusal` | `src/internal/header` | Core of `BlockHeader::check`: refuses a block past Block_Maximum_Size, then an empty compressed block, and nothing else | unbounded | none | Z3, CVC5 |
| `dictionary_id_size` | `src/internal/frame` | DID_Field_Size from Dictionary_ID_Flag: 0, 1, 2 or 4 (section 3.1.1.1.1.6) | machine-int | none | Z3, CVC5 |
| `content_size_size` | `src/internal/frame` | FCS_Field_Size from Frame_Content_Size_Flag and Single_Segment_Flag: 0 or 1, 2, 4, 8 (section 3.1.1.1.1.1) | machine-int | none | Z3, CVC5 |
| `header_len` | `src/internal/frame` | Core of `frame_header_len`: the descriptor, the Window_Descriptor unless single-segment, and the two fields, 2 to 14 bytes; refused exactly for the reserved bit | machine-int | none | Z3, CVC5 |
| `window_size` | `src/internal/frame` | Core of the header package's `window_size`: `2^(10 + Exponent) + 2^(10 + Exponent) / 8 * Mantissa` (section 3.1.1.1.2), at most 2^41 + 7 * 2^38, with no overflow in 64 bits | machine-int | `shl1_u64`, `mantissa_u64` | Z3, CVC5 |

## Trusted bridges

| Bridge | Package | Claim | Backing test |
| --- | --- | --- | --- |
| `shr` | `src/internal/proof_bits` | `x >> k` is `x / 2^k` for `x >= 0`, `0 <= k <= 30` | `src/internal/proof_bits/shifts_test.mbt`: "shr and low_bits are division and remainder by 2^k" |
| `low_bits` | `src/internal/proof_bits` | `x & (2^k - 1)` is `x % 2^k` for `x >= 0`, `0 <= k <= 30` | `src/internal/proof_bits/shifts_test.mbt`: "shr and low_bits are division and remainder by 2^k" |
| `shl` | `src/internal/proof_bits` | `x << k` is `x * 2^k` for `x >= 0`, `0 <= k <= 30`, while that fits an `Int` | `src/internal/proof_bits/shifts_test.mbt`: "shl is multiplication by 2^k while the product fits" |
| `shl1_u64` | `src/internal/frame` | `1UL << k` is 2^k for `10 <= k <= 41` | `src/internal/frame/bridges_wbtest.mbt`: "shl1_u64 is 2^k for every window exponent" |
| `mantissa_u64` | `src/internal/frame` | `m.to_uint64()` is `m` for `0 <= m <= 7` | `src/internal/frame/bridges_wbtest.mbt`: "mantissa_u64 is the mantissa for every mantissa" |

`src/internal/proof_bits` is a copy of `parts/proof_bits`, where lemmas check
that its table of powers of two doubles at every step. The proof of
`literals_header_of` also uses the lemma of `src/internal/proof_fields`, a
copy of `parts/proof_fields`, proved there: a bit field read with division
and remainder is the field. The tables behind
`shl1_u64` and `mantissa_u64` have no lemmas (in the package, they kept
`window_size` from being proved); `scripts/proof_check.mbtx` checks their
entries instead.

Bridge budget: 5
