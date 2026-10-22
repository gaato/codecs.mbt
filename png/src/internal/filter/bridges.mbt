// Trusted bridges for the proofs of this package, which `moon prove`
// assumes; bridges_wbtest.mbt checks each over its whole domain. The shared
// bridges are in internal/proof_bits.

///|
/// `a + b` on bytes, which wraps: the prover has no `Byte::add`. Through
/// `Int`, which Wasm GC runs as fast as without the bridge, where `Byte`'s
/// `+` decoded the benchmarks' images 3 to 7% slower.
fn byte_add(
  a : Byte,
  b : Byte,
) -> Byte where {
  proof_axiomatized: true,
  proof_require: true,
  proof_ensure: result => result.to_int() == (a.to_int() + b.to_int()) % 256,
} {
  (a.to_int() + b.to_int()).to_byte()
}

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
