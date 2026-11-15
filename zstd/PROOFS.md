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
| `settle` | `src/internal/fse` | Core of `normalize`, the encoder's normalized distribution (section 4.1.1): whatever shares it is given for the symbols of `counts[0:n]` (at most 2^17 in all, the last one seen, `n` at most the `size` of 2^5 to 2^9 states), the probabilities it writes take exactly `size` states, a -1 taking one, and fit the counts: 0 for a symbol never seen, at least 1 or -1 for every other | unbounded | none | Z3, CVC5 |
| `build_table` | `src/internal/huffman` | Core of `Huffman::build` (section 4.2.1): refuses the weights, with the reason, exactly by the decoder's checks in order (a weight above 11; no weight but the implied one; Max_Number_of_Bits, the number of bits of the sum of 2^(Weight - 1), above 11; a gap to 2^Max_Number_of_Bits that is not a power of 2; no weight of 1, the implied one included), and never for overfilling the table; otherwise gives the implied last weight, `log2(gap) + 1`, returns Max_Number_of_Bits, and fills the table: the weights' shares make up its 2^Max_Number_of_Bits entries, and each symbol of weight `w > 0` has the 2^(w - 1) entries of its place in the order of weights and then symbols, each with the symbol and the code length `Max_Number_of_Bits + 1 - w`. It reads only inside its tables and writes the weights not at all | unbounded | `shl`, `byte_of` | Z3 only: CVC5 1.4.2 runs out of time on 11 of its goals at 30 s each, in `build_table`, `fill` and `place_apart`: the sums of the counts with a variable Max_Number_of_Bits, the case split on how two symbols' weights compare, and the frame of the table's blocks |
| `reverse_bits` | `parts/huffman` | The low `n` bits of `code` (`n` up to 15) in reverse order, as `rev` of `parts/proof_codes` defines them (bit `j` becomes bit `n - 1 - j`), and below 2^n | unbounded | `shr`, `low_bits` | Z3, CVC5 |
| `involution` | `parts/proof_reverse` | `rev` is an involution: reversing the `n` bits of a number below 2^n twice gives the number back, for `n` up to 15 | unbounded | none | Z3, CVC5 |
| `canonical_into` | `parts/huffman` | Core of `canonical_codes` (RFC 1951 section 3.2.2): `count` counts the code lengths, and each symbol's code is its canonical code reversed, the first code of its length (`next_code`) plus the symbols of that length before it; a symbol without a code gets 0 | unbounded | none | Z3, CVC5 |
| `canonical_order` | `parts/proof_canonical` | The canonical codes increase in canonical order and form a prefix code: when `s` comes before `t` (a shorter code, or as long and a smaller symbol), the 15-bit sequences that start with `s`'s code all come before those that start with `t`'s | unbounded | none | Z3, CVC5 |
| `canonical_fits` | `parts/proof_canonical` | With Kraft's sum at most 1, each canonical code fits its length: the sequences it starts end within the code space | unbounded | none | Z3, CVC5 |


## Not proved

- `Fse::build` and `Fse::read` (`src/fse.mbt`), the decoder's FSE tables,
  and `spread` (`src/internal/fse`), where they and the encoder's tables
  put each symbol: that every state gets one symbol when the probabilities
  add up to the table. It holds because the walk from state 0 in odd steps
  covers a table of 2^log states, skipping those the -1 symbols took, a fact
  of modular arithmetic the solvers do not find. It depends only on the
  table's size and how many states the -1 symbols took, so
  `src/internal/fse/fse_test.mbt` checks it for every table log the format
  uses (5 to 9) and every such count: "spread's walk visits each state
  below the -1 symbols once, then returns to 0".
- `Dictionary::parse` (`src/dictionary.mbt`): its tables are read by
  `Huffman::read` and `Fse::read`, unproved like the above, and it checks
  the repeat offsets against the content. "formatted dictionaries that do
  not parse are Corrupt" cuts them at every kind of place, and the
  dictionaries `zstd --train` writes decode as zstd decodes them.
- XXH64 (`src/internal/xxhash`): 64-bit multiplications and rotations,
  which the prover's integers do not model. Its tests compare digests with
  the reference's for every length 1 to 96 at all sixteen alignments, and
  split the input every way around its stripes.
- `code_lengths` and `CodeMaker::make` (`src/internal/huffman_code`, a copy
  of `parts/huffman`), the encoder's Huffman codes: brotli/PROOFS.md says
  why, and `src/internal/huffman_code/code_maker_test.mbt` tests them.

## Trusted bridges

| Bridge | Package | Claim | Backing test |
| --- | --- | --- | --- |
| `shr` | `src/internal/proof_bits` | `x >> k` is `x / 2^k` for `x >= 0`, `0 <= k <= 30` | `src/internal/proof_bits/shifts_test.mbt`: "shr and low_bits are division and remainder by 2^k" |
| `low_bits` | `src/internal/proof_bits` | `x & (2^k - 1)` is `x % 2^k` for `x >= 0`, `0 <= k <= 30` | `src/internal/proof_bits/shifts_test.mbt`: "shr and low_bits are division and remainder by 2^k" |
| `shl` | `src/internal/proof_bits` | `x << k` is `x * 2^k` for `x >= 0`, `0 <= k <= 30`, while that fits an `Int` | `src/internal/proof_bits/shifts_test.mbt`: "shl is multiplication by 2^k while the product fits" |
| `shl1_u64` | `src/internal/frame` | `1UL << k` is 2^k for `10 <= k <= 41` | `src/internal/frame/bridges_wbtest.mbt`: "shl1_u64 is 2^k for every window exponent" |
| `mantissa_u64` | `src/internal/frame` | `m.to_uint64()` is `m` for `0 <= m <= 7` | `src/internal/frame/bridges_wbtest.mbt`: "mantissa_u64 is the mantissa for every mantissa" |
| `byte_of` | `src/internal/huffman` | `x.to_byte().to_int()` is `x` for `0 <= x <= 255` | `src/internal/huffman/bridges_wbtest.mbt`: "byte_of is to_byte, for every byte" |

`src/internal/proof_bits` is a copy of `parts/proof_bits`, where lemmas check
that its table of powers of two doubles at every step. The proof of
`literals_header_of` also uses the lemma of `src/internal/proof_fields`, a
copy of `parts/proof_fields`, proved there: a bit field read with division
and remainder is the field. The tables behind
`shl1_u64` and `mantissa_u64` have no lemmas (in the package, they kept
`window_size` from being proved); `scripts/proof_check.mbtx` checks their
entries instead.

`Huffman::build` stores the implied last weight that `build_table` leaves
in its scratch space after the others, and turns a refusal into the
decoder's message. `build_table` counts the weights with `occ` of Why3's
map.Occ, through `src/internal/proof_codes` (a copy of `parts/proof_codes`):
its `#proof_import` declarations, of `occ` and of an array's elements, are
trusted like the bridges to say what those Why3 symbols are.

`settle` sums and counts the probabilities with `sum` of Why3's int.Sum
and `occ` of map.Occ, on the array's elements, through `#proof_import`
declarations in `src/internal/fse/normalize.mbtp`, trusted like the bridges
to say what those Why3 symbols are, as is `set` of map.Map. With them come
two lemmas the prover proves there: writing an element leaves the sum and
the counts of the elements before it as they were. Z3 does not find that
from the library's own extensionality lemmas when a proof writes an
element; stated on `set`, where an array's write lands, it does.
`normalize` shares out the states first, rounding as the reference
encoder does, and `settle` writes them out; the tests check that the shares
already add up and fit, so that `settle` only writes them
(`src/internal/fse/share_out_wbtest.mbt`), and that it repairs any that do
not.

Bridge budget: 6

Sequence encoding and fast/double-fast/hash-chain matching add no trusted bridges
or formal proof claims. Length baselines and
predefined distributions now live in `src/internal/seqenc/tables.mbt` and
are referenced by both directions. Repeat history transitions likewise
have one executable implementation, `Repeats::resolve`; the encoder's
inverse is checked against independent RFC transitions in
`src/internal/seqenc/offset_test.mbt`. Sequence interleaving, mode validity,
and match window eligibility rest on tests and external decoding, rather
than on the entropy normalization proof above. See
`docs/compression.md` for the cost model and measured limitations.
