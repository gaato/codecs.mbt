// A trusted bridge for update_bytes, which `moon prove` assumes;
// bridges_wbtest.mbt checks it for every byte.

///|
/// `b.to_uint()`: the prover has no `Byte::to_uint`.
fn byte_u32(
  b : Byte,
) -> UInt32 where {
  proof_axiomatized: true,
  proof_ensure: result => um(result).eq(im(b.to_int())),
} {
  b.to_uint()
}
