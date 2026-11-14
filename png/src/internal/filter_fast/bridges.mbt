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

///|
/// Writes the first four bytes of `v` over `a[off:off + 4]`, which must lie
/// within it.
#cfg(any(target="native", target="wasm"))
fn store4(
  a : FixedArray[Byte],
  off : Int32,
  v : V128,
) -> Unit where {
  proof_axiomatized: true,
  proof_require: 0 <= off && off + 4 <= a.length(),
  proof_ensure: true,
} {
  @v128.v128_store32_lane(a, off, v, 0)
}

///|
/// Average's prediction for each byte: `(a + b) / 2`, rounded down.
/// `i8x16_avgr_u` rounds up, so the low bit of `a ^ b` comes off.
#cfg(any(target="native", target="wasm"))
fn avg16(
  a : V128,
  b : V128,
) -> V128 where {
  proof_axiomatized: true,
  proof_require: true,
  proof_ensure: _result => true,
} {
  @v128.i8x16_sub(
    @v128.i8x16_avgr_u(a, b),
    @v128.v128_and_(@v128.v128_xor(a, b), @v128.i8x16_splat(b'\x01')),
  )
}

///|
/// Paeth's prediction (`@filter.paeth`) for each of the first eight bytes,
/// from the byte on the left `a`, the one above `b` and the one above left
/// `c`, as libpng's SSE2 filter computes it: the distances in 16-bit lanes,
/// the nearest picked with ties going to `a`, then `b`. The upper eight
/// bytes of the result are those of the lower eight again.
#cfg(any(target="native", target="wasm"))
fn paeth16(
  a : V128,
  b : V128,
  c : V128,
) -> V128 where {
  proof_axiomatized: true,
  proof_require: true,
  proof_ensure: _result => true,
} {
  let a = @v128.i16x8_extend_low_i8x16_u(a)
  let b = @v128.i16x8_extend_low_i8x16_u(b)
  let c = @v128.i16x8_extend_low_i8x16_u(c)
  // |p - a| = |b - c|, |p - b| = |a - c| and |p - c| = |a + b - 2c|.
  let pa = @v128.i16x8_abs(@v128.i16x8_sub(b, c))
  let pb = @v128.i16x8_abs(@v128.i16x8_sub(a, c))
  let pc = @v128.i16x8_abs(
    @v128.i16x8_sub(@v128.i16x8_add(a, b), @v128.i16x8_add(c, c)),
  )
  let least = @v128.i16x8_min_s(pc, @v128.i16x8_min_s(pa, pb))
  let nearest = @v128.v128_bitselect(
    a,
    @v128.v128_bitselect(b, c, @v128.i16x8_eq(least, pb)),
    @v128.i16x8_eq(least, pa),
  )
  @v128.i8x16_narrow_i16x8_u(nearest, nearest)
}
