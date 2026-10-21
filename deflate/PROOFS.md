# Proofs

`moon prove` (Why3 and an SMT solver) checks the functions below against
RFC 1950 and RFC 1952: the code that runs, not a model of it. Each proof holds
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

`update`, the decoder's Adler-32 over an `ArrayView`, is the same code as
`update_bytes` but is not proved: the prover does not model `ArrayView`. The
test "update_bytes equals update, in pieces" compares them.

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
