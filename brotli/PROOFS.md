# Proofs

`moon prove` (Why3 and an SMT solver) checks the functions below against
RFC 7932: the code that runs, not a model of it. Each proof holds for the
inputs its precondition allows, which the decoder's reads guarantee (a field of
`n` bits is below `2^n`, a code is in its alphabet).

Run them with `moon run scripts/prove.mbtx` from the repository root (Z3
4.16.0 on PATH), and with `-- --solver cvc5` for the second solver (CVC5
1.4.2). `moon run scripts/proof_check.mbtx -- brotli` checks this ledger
against the code.

## What is trusted

- The bridges below: `moon prove` takes their contracts as given. Each is a
  bit operation or a conversion the prover does not model, and its tests check
  it over its precondition's domain.
- The solvers, Why3 and moonc's translation to Why3. Z3 and CVC5 each prove
  every function here but one, which only Z3 proves; negative controls
  (`parts/proof_controls`) check that each solver refuses false claims.
- With the unbounded prelude, integers do not overflow in the proof. The
  preconditions bound every value the functions compute well below 2^31.

## Proved

| Function | Package | Property | Prelude | Bridges | Solvers |
| --- | --- | --- | --- | --- | --- |
| `window_bits` | `src/internal/rules` | WBITS and the header's length are the entry of section 9.1's table whose bit pattern starts the header; `None` exactly for the reserved pattern 0010001 | unbounded | `shr`, `low_bits` | Z3, CVC5 |
| `meta_block_length` | `src/internal/rules` | MLEN is the nibbles' value plus 1, at most 2^24; `None` exactly when more than four nibbles end in a zero one (section 9.2) | unbounded | `shr` | Z3, CVC5 |
| `metadata_length` | `src/internal/rules` | 0 for no bytes, else the bytes' value plus 1, at most 2^24; `None` exactly when more than one byte ends in a zero one (section 9.2) | unbounded | `shr` | Z3, CVC5 |
| `next_block_type` | `src/internal/rules` | Codes 0, 1 and `2 + t` name the second-to-last type, the last plus one and type `t`, modulo NBLTYPES; the result is a type (section 6) | unbounded | none | Z3, CVC5 |
| `distance_extra_bits` | `src/internal/rules` | `ndistbits` of section 4, 0 to 24, for every code of the alphabet | unbounded | `shr` | Z3, CVC5 |
| `distance` | `src/internal/rules` | Short codes follow section 4's table of last distances and deltas, `None` exactly when that is below 1; direct codes name `code - 15`; codes with extra bits section 4's formula, always past NDIRECT | unbounded | `shr`, `low_bits`, `shl` | Z3, CVC5 |
| `long_distance` | `src/internal/rules` | `distance` for codes with extra bits: section 4's formula, past NDIRECT, and no shift overflows | unbounded | `shl`, `low_bits` | Z3 only: CVC5 1.4.2 does not prove the steps that evaluate the table of powers of two at NPOSTFIX, a variable (five goals, at 30 s each) |
| `long_offset` | `src/internal/rules` | The offset of section 4's formula, `((2 + (hcode & 1)) << ndistbits) - 4`, and the bound that keeps the shifts after it from overflowing | unbounded | `shr`, `low_bits`, `shl` | Z3, CVC5 |
| `short_code_distance` | `src/internal/rules` | `distance` for short codes: section 4's table | unbounded | `shr`, `low_bits` | Z3, CVC5 |
| `move_to_front` | `src/internal/rules` | Each step of `inverse_move_to_front` (section 7.3): keeps the list a permutation of 0 to 255 and puts the chosen entry first | unbounded | none | Z3, CVC5 |
| `transform_into` | `src/internal/transform` | Core of `transform_word` (section 8): writes the prefix, the word uppercased as FermentFirst or FermentAll say, and the suffix only inside the caller's buffer, when the three fit it, and returns their length; FermentFirst needs a word, and `ferment` writes only inside it | unbounded | `flip` | Z3, CVC5 |
| `reverse_bits` | `parts/huffman` | The low `n` bits of `code` (`n` up to 15) in reverse order, as `rev` of `parts/proof_codes` defines them (bit `j` becomes bit `n - 1 - j`), and below 2^n | unbounded | `shr`, `low_bits` | Z3, CVC5 |
| `involution` | `parts/proof_reverse` | `rev` is an involution: reversing the `n` bits of a number below 2^n twice gives the number back, for `n` up to 15 | unbounded | none | Z3, CVC5 |
| `canonical_into` | `parts/huffman` | Core of `canonical_codes` (RFC 1951 section 3.2.2): `count` counts the code lengths, and each symbol's code is its canonical code reversed, the first code of its length (`next_code`) plus the symbols of that length before it; a symbol without a code gets 0 | unbounded | none | Z3, CVC5 |
| `canonical_order` | `parts/proof_canonical` | The canonical codes increase in canonical order and form a prefix code: when `s` comes before `t` (a shorter code, or as long and a smaller symbol), the 15-bit sequences that start with `s`'s code all come before those that start with `t`'s | unbounded | none | Z3, CVC5 |
| `canonical_fits` | `parts/proof_canonical` | With Kraft's sum at most 1, each canonical code fits its length: the sequences it starts end within the code space | unbounded | none | Z3, CVC5 |

`inverse_move_to_front` itself returns nothing, so it has no postcondition,
but `moon prove` checks its body too: every index is in bounds, and the list
starts as the identity and stays a permutation through every step (its loop
invariants, with `byte_of`). The proof does not cover that it writes only
`values[0..n)`, which `context_map_test.mbt` checks.

`transform_word`, in the root package, looks up the transform's prefix,
suffix and elementary transform in Appendix B's tables and cuts the word out
of the dictionary, then calls `transform_into`. That the tables' prefixes
and suffixes leave room for any word, at most 13 bytes together with 24 for
the word in the 37-byte buffer, is what `transform_into` requires and is not
proved: the test "transform_word: the longest word under the longest
transform fills the buffer" checks it over the 121 transforms.

The rows in `parts/` are proved once, where the parts live; this module's
copies of them (`src/internal/huffman`, `src/internal/proof_codes`,
`src/internal/proof_bits`) are the same files, which
`moon run scripts/gen_parts.mbtx -- --check` keeps so. The packages
`parts/proof_reverse` and `parts/proof_canonical` hold theorems about the
definitions of `parts/proof_codes` and are not copied.

`parts/proof_codes` counts code lengths with `occ` of Why3's map.Occ, which
its axioms define, imported through `#proof_import` together with the
elements of an array (`elts` of array.Array). Those two declarations are
trusted, like the bridges, to say what the Why3 symbols are.

## Not proved

- `code_lengths` (`parts/huffman`, Brotli's encoder): that its lengths stay
  within the limit, that Kraft's sum is exactly 1 and that unused symbols
  get 0. It keeps the used symbols in an `Array` sorted with `sort_by`,
  which the prover does not model, and its retry loop has no measure that
  shows it ends. Kraft's sum of 1 is a property of the tree it builds in
  parent links, and stating it needs a sum over the tree's leaves: the
  toolchain gives a recursive logic function no definition the solvers can
  use (a recursive `fn` of a `.mbtp` lowers to a Why3 `let rec ghost
  function` over program operations, which stays opaque). The tests
  "code lengths stay within the limit and the code stays complete" and
  "code lengths: within the limit, complete, and optimal when nothing is
  cut" check it.
- `CodeMaker::make` (`parts/huffman`, DEFLATE's encoder): the same
  properties. Its counting of code lengths keeps Kraft's sum at exactly 1
  by construction, but that no count goes below 0 rests on libdeflate's
  argument that the tree's depths only grow as it is walked, which needs
  the tree, packed with the frequencies and symbols in one array, as a
  model. Not attempted in this round; "CodeMaker: within the limit,
  complete, canonical, and optimal when nothing is cut" tests it.
- `Builder::build` (`parts/huffman`, the decoders' tables): that each entry
  matches the canonical code, that unreached entries keep the caller's
  value, that writes stay in the table and that the size stays within
  `max_entries`. Its table holds `UInt16`, which the prover does not model
  (no `UInt16` in its prelude; `.to_int()` of one is refused in logic).
  Matching entries to codes needs, besides `canonical_order`, that the low
  `l` bits of a reversed `m`-bit code are the reversal of its top `l` bits,
  a fact per pair of lengths of the kind `parts/proof_reverse` proves for
  `rev` itself; and the second-level tables are found through links read
  back from the table, so even that writes stay in the table rests on it.
  `max_entries` is zlib's `enough`, a maximum over every code found by
  exhaustive search, which is not a question for the solvers. The tests of
  `decode_table_spec_test.mbt` and `enough_test.mbt` check these.

## Trusted bridges

| Bridge | Package | Claim | Backing test |
| --- | --- | --- | --- |
| `shr` | `src/internal/proof_bits` | `x >> k` is `x / 2^k` for `x >= 0`, `0 <= k <= 30` | `src/internal/proof_bits/shifts_test.mbt`: "shr and low_bits are division and remainder by 2^k" |
| `low_bits` | `src/internal/proof_bits` | `x & (2^k - 1)` is `x % 2^k` for `x >= 0`, `0 <= k <= 30` | `src/internal/proof_bits/shifts_test.mbt`: "shr and low_bits are division and remainder by 2^k" |
| `shl` | `src/internal/proof_bits` | `x << k` is `x * 2^k` for `x >= 0`, `0 <= k <= 30`, while that fits an `Int` | `src/internal/proof_bits/shifts_test.mbt`: "shl is multiplication by 2^k while the product fits" |
| `byte_of` | `src/internal/rules` | `x.to_byte().to_int()` is `x` for `0 <= x <= 255` | `src/internal/rules/bridges_wbtest.mbt`: "byte_of is to_byte, for every byte" |
| `flip` | `src/internal/transform` | `b ^ mask` is a byte: it claims nothing about which, since the proof is about where bytes go | `src/internal/transform/bridges_wbtest.mbt`: "flip is ^, for every byte and the masks Ferment uses" |

`src/internal/proof_bits` is a copy of `parts/proof_bits`, where lemmas check
that its table of powers of two doubles at every step.

Bridge budget: 5
