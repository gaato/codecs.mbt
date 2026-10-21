# Proofs

`moon prove` (Why3 and an SMT solver) checks the functions below against
RFC 1950, RFC 1951 and RFC 1952: the code that runs, not a model of it. Each proof holds
for the inputs its precondition allows, which the callers guarantee (header
bytes are bytes).

The header functions are the cores of functions that return a `Result`,
which the prover does not model: the public function turns the core's answer
into the `Result` and its message. The tests check the public functions, the
zlib header over every pair of bytes, against references written from the
RFCs.

Run the proofs with `moon run scripts/prove.mbtx` from the repository root
(Z3 4.16.0 on PATH), and with `-- --solver cvc5` for the second solver (CVC5
1.4.2). `moon run scripts/proof_check.mbtx -- deflate` checks this ledger
against the code.

## What is trusted

- The bridges below: `moon prove` takes their contracts as given. Each is a
  bit operation or a conversion the prover does not model, and its tests check
  it over its precondition's domain.
- The solvers, Why3 and moonc's translation to Why3. Negative controls
  (`parts/proof_controls`) check that each solver refuses false claims.
- With the unbounded prelude, integers do not overflow in the proof; the
  preconditions bound every value well below 2^31. `src/zlib/internal/adler32`
  is proved with the machine-integer prelude instead, where every `+` and `*`
  is proved not to overflow.

## Proved

| Function | Package | Property | Prelude | Bridges | Solvers |
| --- | --- | --- | --- | --- | --- |
| `header_of` | `src/zlib/internal/header` | Core of `parse` (RFC 1950 section 2.2): refused, with the reason, exactly by zlib's checks in order (FCHECK: CMF * 256 + FLG a multiple of 31; CM 8; CINFO at most 7); an accepted header's window is 2^(CINFO + 8), 2^8 to 2^15 bytes, its level FLEVEL and its dictionary flag FDICT | unbounded | `shr`, `low_bits` | Z3, CVC5 |
| `start_refusal` | `src/gzip/internal/header` | Core of `check_start` (RFC 1952 section 2.3.1): refuses, in order, a magic number other than 1f 8b, a method other than 8, and a reserved flag (bits 5 to 7), and nothing else | unbounded | `shr` | Z3, CVC5 |
| `update_bytes` | `src/zlib/internal/adler32` | No sum passes 2^32 - 1 between reductions with zlib's NMAX of 5552 bytes (the proof fails at 5553), and both halves of a checksum that has absorbed a byte are reduced modulo 65521 | machine-int | `byte_u32` | Z3 only: CVC5 1.4.2 runs out of time on 23 of its 56 goals at 120 s each (the quadratic bound on the second sum, in machine integers) |
| `shape` | `src/internal/inflate` | The decoder's judgement of a code's lengths (RFC 1951 section 3.2.2, as zlib's inftrees.c reads them), lengths of 0 to 15: `counts` ends up counting them, and the verdict is the one Kraft's sum of the counts (the sum of 2^(15 - length) over the symbols with a code) gives: `Bad` exactly when it is over 2^15, `Complete` exactly when it is 2^15, and below, `Lone` for one code of one bit, `Empty` for no code at all, `Bad` otherwise | unbounded | none | Z3, CVC5 |
| `reverse_bits` | `parts/huffman` | The low `n` bits of `code` (`n` up to 15) in reverse order, as `rev` of `parts/proof_codes` defines them (bit `j` becomes bit `n - 1 - j`), and below 2^n | unbounded | `shr`, `low_bits` | Z3, CVC5 |
| `involution` | `parts/proof_reverse` | `rev` is an involution: reversing the `n` bits of a number below 2^n twice gives the number back, for `n` up to 15 | unbounded | none | Z3, CVC5 |
| `canonical_into` | `parts/huffman` | Core of `canonical_codes` (RFC 1951 section 3.2.2): `count` counts the code lengths, and each symbol's code is its canonical code reversed, the first code of its length (`next_code`) plus the symbols of that length before it; a symbol without a code gets 0 | unbounded | none | Z3, CVC5 |
| `canonical_order` | `parts/proof_canonical` | The canonical codes increase in canonical order and form a prefix code: when `s` comes before `t` (a shorter code, or as long and a smaller symbol), the 15-bit sequences that start with `s`'s code all come before those that start with `t`'s | unbounded | none | Z3, CVC5 |
| `canonical_fits` | `parts/proof_canonical` | With Kraft's sum at most 1, each canonical code fits its length: the sequences it starts end within the code space | unbounded | none | Z3, CVC5 |

`update`, the decoder's Adler-32 over an `ArrayView`, is the same code as
`update_bytes` but is not proved: the prover does not model `ArrayView`. The
test "update_bytes equals update, in pieces" compares them.

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
| `byte_u32` | `src/zlib/internal/adler32` | `b.to_uint()` is the byte's value | `src/zlib/internal/adler32/bridges_wbtest.mbt`: "byte_u32 is to_uint, for every byte" |

`src/internal/proof_bits` is a copy of `parts/proof_bits`, where lemmas check
that its table of powers of two doubles at every step.

Bridge budget: 4
