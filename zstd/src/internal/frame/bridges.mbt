// Trusted bridges for window_size, which `moon prove` assumes; bridges_wbtest.mbt
// checks each over its whole domain.

///|
/// `1UL << k` for a window exponent, 10 to 41.
fn shl1_u64(
  k : Int32,
) -> UInt64 where {
  proof_axiomatized: true,
  proof_require: 10 <= k && k <= 41,
  proof_ensure: result => result == pow2_u64(k),
} {
  1UL << k
}

///|
/// `m.to_uint64()` for a mantissa, 0 to 7: the prover has no
/// `Int::to_uint64`.
fn mantissa_u64(
  m : Int32,
) -> UInt64 where {
  proof_axiomatized: true,
  proof_require: 0 <= m && m <= 7,
  proof_ensure: result => result == small_u64(m),
} {
  m.to_uint64()
}
