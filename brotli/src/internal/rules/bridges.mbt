// A trusted bridge for the proofs of this package, which `moon prove`
// assumes; bridges_test.mbt checks it over its whole domain. The shared
// bridges are in internal/proof_bits.

///|
/// `x.to_byte()` for `x` from 0 to 255: the prover has no `Int::to_byte`.
fn byte_of(
  x : Int32,
) -> Byte where {
  proof_axiomatized: true,
  proof_require: 0 <= x && x <= 255,
  proof_ensure: result => result.to_int() == x,
} {
  x.to_byte()
}
