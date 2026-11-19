// Generated from parts/copy16/copy16.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
/// Copies 16 bytes within `dst`. The caller ensures `0 <= from`,
/// `to - from >= 16`, and `to + 16 <= dst.length()`. Bytes past the real
/// copy length are scratch. The caller must overwrite them or never read them.
#cfg(any(target="native", target="wasm"))
pub fn copy16(dst : FixedArray[Byte], to : Int32, from : Int32) -> Unit {
  // Both 16-byte ranges fit and are disjoint by the caller's bounds.
  let src = dst.unsafe_reinterpret_as_bytes()
  dst.unsafe_write_uint64_le(to, src.unsafe_read_uint64_le(from))
  dst.unsafe_write_uint64_le(to + 8, src.unsafe_read_uint64_le(from + 8))
}

///|
/// Copies 16 bytes within `dst` under the same bounds and scratch contract.
#cfg(target="js")
pub fn copy16(dst : FixedArray[Byte], to : Int32, from : Int32) -> Unit {
  // Both 16-byte ranges fit and are disjoint by the caller's bounds.
  for i in 0..<16 {
    dst.unsafe_set(to + i, dst.unsafe_get(from + i))
  }
}

///|
/// Copies 16 bytes within `dst` under the same bounds and scratch contract.
#cfg(target="wasm-gc")
pub fn copy16(dst : FixedArray[Byte], to : Int32, from : Int32) -> Unit {
  // Both 16-byte ranges fit and are disjoint by the caller's bounds.
  FixedArray::unsafe_blit(dst, to, dst, from, 16)
}

///|
/// Copies 16 bytes from `src` at `at` into `dst` at `to`. The caller
/// ensures that both ranges fit and that `src` does not view `dst`.
/// Bytes past the real copy length are scratch. The caller must overwrite
/// them or never read them.
#cfg(any(target="native", target="wasm"))
pub fn copy16_from_view(
  dst : FixedArray[Byte],
  to : Int32,
  src : BytesView,
  at : Int32,
) -> Unit {
  // The caller guarantees all 16 source and destination bytes are in range.
  dst.unsafe_write_uint64_le(to, src.unsafe_read_uint64_le(at))
  dst.unsafe_write_uint64_le(to + 8, src.unsafe_read_uint64_le(at + 8))
}

///|
/// Copies from a view under the same bounds and scratch contract.
#cfg(target="js")
pub fn copy16_from_view(
  dst : FixedArray[Byte],
  to : Int32,
  src : BytesView,
  at : Int32,
) -> Unit {
  // The caller guarantees all 16 source and destination bytes are in range.
  for i in 0..<16 {
    dst.unsafe_set(to + i, src.unsafe_get(at + i))
  }
}

///|
/// Copies from a view under the same bounds and scratch contract.
#cfg(target="wasm-gc")
pub fn copy16_from_view(
  dst : FixedArray[Byte],
  to : Int32,
  src : BytesView,
  at : Int32,
) -> Unit {
  dst.blit_from_bytesview(to, src[at:at + 16])
}
