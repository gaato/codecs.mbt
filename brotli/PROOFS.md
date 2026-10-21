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

`inverse_move_to_front` itself returns nothing, so it has no postcondition,
but `moon prove` checks its body too: every index is in bounds, and the list
starts as the identity and stays a permutation through every step (its loop
invariants, with `byte_of`). The proof does not cover that it writes only
`values[0..n)`, which `context_map_test.mbt` checks.

## Trusted bridges

| Bridge | Package | Claim | Backing test |
| --- | --- | --- | --- |
| `shr` | `src/internal/proof_bits` | `x >> k` is `x / 2^k` for `x >= 0`, `0 <= k <= 30` | `src/internal/proof_bits/shifts_test.mbt`: "shr and low_bits are division and remainder by 2^k" |
| `low_bits` | `src/internal/proof_bits` | `x & (2^k - 1)` is `x % 2^k` for `x >= 0`, `0 <= k <= 30` | `src/internal/proof_bits/shifts_test.mbt`: "shr and low_bits are division and remainder by 2^k" |
| `shl` | `src/internal/proof_bits` | `x << k` is `x * 2^k` for `x >= 0`, `0 <= k <= 30`, while that fits an `Int` | `src/internal/proof_bits/shifts_test.mbt`: "shl is multiplication by 2^k while the product fits" |
| `byte_of` | `src/internal/rules` | `x.to_byte().to_int()` is `x` for `0 <= x <= 255` | `src/internal/rules/bridges_wbtest.mbt`: "byte_of is to_byte, for every byte" |

`src/internal/proof_bits` is a copy of `parts/proof_bits`, where lemmas check
that its table of powers of two doubles at every step.

Bridge budget: 4
