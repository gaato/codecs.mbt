// The SIMD operations of the Up filter, which a proved function's body
// cannot hold: each is trusted, as PROOFS.md lists, and backed by
// bridges_wbtest.mbt. Their contracts state only where they read and write.

///|
/// Sixteen bytes of `a` from `off`, which must lie within it.
#cfg(any(target="native", target="wasm"))
fn load16(
  a : FixedArray[Byte],
  off : Int32,
) -> V128 where {
  proof_axiomatized: true,
  proof_require: 0 <= off && off + 16 <= a.length(),
  proof_ensure: _result => true,
} {
  @v128.v128_load(a, off)
}

///|
/// Writes `v` over sixteen bytes of `a` from `off`, which must lie within it.
#cfg(any(target="native", target="wasm"))
fn store16(
  a : FixedArray[Byte],
  off : Int32,
  v : V128,
) -> Unit where {
  proof_axiomatized: true,
  proof_require: 0 <= off && off + 16 <= a.length(),
  proof_ensure: true,
} {
  @v128.v128_store(a, off, v)
}

///|
/// The sixteen bytes of `x` plus those of `y`, each wrapped to a byte.
#cfg(any(target="native", target="wasm"))
fn add16(
  x : V128,
  y : V128,
) -> V128 where {
  proof_axiomatized: true,
  proof_require: true,
  proof_ensure: _result => true,
} {
  @v128.i8x16_add(x, y)
}
