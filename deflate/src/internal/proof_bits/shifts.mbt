// Generated from parts/proof_bits/shifts.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// Bit operations behind contracts that state their arithmetic. `moon prove`
// trusts these contracts (`proof_axiomatized`); shifts_test.mbt checks them.

///|
/// `x >> k` for non-negative `x`: `x / 2^k`.
pub fn shr(
  x : Int32,
  k : Int32,
) -> Int32 where {
  proof_axiomatized: true,
  proof_require: 0 <= x && shift_ok(k),
  proof_ensure: result => result == x / pow2(k),
} {
  x >> k
}

///|
/// `x & (2^k - 1)` for non-negative `x`: `x % 2^k`, the low `k` bits.
pub fn low_bits(
  x : Int32,
  k : Int32,
) -> Int32 where {
  proof_axiomatized: true,
  proof_require: 0 <= x && shift_ok(k),
  proof_ensure: result => result == x % pow2(k),
} {
  x & ((1 << k) - 1)
}

///|
/// `x << k` for non-negative `x` when the result fits an `Int`: `x * 2^k`.
/// The prover's integers are unbounded, so the precondition is what keeps
/// the contract true at run time.
pub fn shl(
  x : Int32,
  k : Int32,
) -> Int32 where {
  proof_axiomatized: true,
  proof_require: 0 <= x && shift_ok(k) && x * pow2(k) <= 2147483647,
  proof_ensure: result => result == x * pow2(k),
} {
  x << k
}
