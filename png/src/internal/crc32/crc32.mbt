// Generated from parts/crc32/crc32.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
/// The CRC-32 of every byte value: the reflected polynomial 0xEDB88320,
/// computed rather than copied.
let table : FixedArray[UInt32] = FixedArray::makei(256, n => {
  let mut c = n.reinterpret_as_uint()
  for _ in 0..<8 {
    c = if (c & 1) != 0 { 0xEDB88320 ^ (c >> 1) } else { c >> 1 }
  }
  c
})

///|
/// The tables of slice-by-8, 8 KiB, computed from `table`: entry `k * 256 +
/// n` is the CRC-32 of byte `n` followed by `k` zero bytes, so that eight
/// bytes are folded in at a time with eight lookups.
let tables : FixedArray[UInt32] = FixedArray::makei(8 * 256, i => {
  let mut c = table[i % 256]
  for _ in 0..<(i / 256) {
    c = table[(c & 0xFF).reinterpret_as_int()] ^ (c >> 8)
  }
  c
})

///|
/// The CRC-32 of no data.
pub const INITIAL : UInt32 = 0

///|
/// `c`, the CRC-32 register (inverted), extended by the eight bytes `lo`
/// (the first four, little-endian) and `hi` (the next four).
fn fold8(c : UInt32, lo : UInt32, hi : UInt32) -> UInt32 {
  let x = c ^ lo
  // Each index is k * 256 plus a byte, k < 8: within the 2,048 entries.
  // Unchecked, because Wasm calls two functions for every checked read
  // (2.35 times as long there, 1.4 on Wasm GC).
  tables.unsafe_get(7 * 256 + (x & 0xFF).reinterpret_as_int()) ^
  tables.unsafe_get(6 * 256 + ((x >> 8) & 0xFF).reinterpret_as_int()) ^
  tables.unsafe_get(5 * 256 + ((x >> 16) & 0xFF).reinterpret_as_int()) ^
  tables.unsafe_get(4 * 256 + (x >> 24).reinterpret_as_int()) ^
  tables.unsafe_get(3 * 256 + (hi & 0xFF).reinterpret_as_int()) ^
  tables.unsafe_get(2 * 256 + ((hi >> 8) & 0xFF).reinterpret_as_int()) ^
  tables.unsafe_get(256 + ((hi >> 16) & 0xFF).reinterpret_as_int()) ^
  tables.unsafe_get((hi >> 24).reinterpret_as_int())
}

///|
/// The CRC-32 of the data so far, `crc`, extended by `data`.
pub fn update(crc : UInt32, data : ArrayView[Byte]) -> UInt32 {
  let mut c = crc ^ 0xFFFFFFFF
  let n = data.length()
  let mut i = 0
  // i + 7 < n: the eight reads are within `data`. (`i + 8 <= n` would
  // wrap past the largest Int for n within 8 of it.)
  while n - i >= 8 {
    let lo = data.unsafe_get(i).to_uint() |
      (data.unsafe_get(i + 1).to_uint() << 8) |
      (data.unsafe_get(i + 2).to_uint() << 16) |
      (data.unsafe_get(i + 3).to_uint() << 24)
    let hi = data.unsafe_get(i + 4).to_uint() |
      (data.unsafe_get(i + 5).to_uint() << 8) |
      (data.unsafe_get(i + 6).to_uint() << 16) |
      (data.unsafe_get(i + 7).to_uint() << 24)
    c = fold8(c, lo, hi)
    i += 8
  }
  // i < n, and the index is a byte.
  while i < n {
    c = table.unsafe_get(
        ((c ^ data.unsafe_get(i).to_uint()) & 0xFF).reinterpret_as_int(),
      ) ^
      (c >> 8)
    i += 1
  }
  c ^ 0xFFFFFFFF
}

///|
/// The CRC-32 of the data so far, `crc`, extended by `data`.
pub fn update_bytes(crc : UInt32, data : BytesView) -> UInt32 {
  let mut c = crc ^ 0xFFFFFFFF
  let n = data.length()
  let mut i = 0
  // i + 7 < n: the eight reads are within `data`. (`i + 8 <= n` would
  // wrap past the largest Int for n within 8 of it.)
  while n - i >= 8 {
    let lo = data.unsafe_get(i).to_uint() |
      (data.unsafe_get(i + 1).to_uint() << 8) |
      (data.unsafe_get(i + 2).to_uint() << 16) |
      (data.unsafe_get(i + 3).to_uint() << 24)
    let hi = data.unsafe_get(i + 4).to_uint() |
      (data.unsafe_get(i + 5).to_uint() << 8) |
      (data.unsafe_get(i + 6).to_uint() << 16) |
      (data.unsafe_get(i + 7).to_uint() << 24)
    c = fold8(c, lo, hi)
    i += 8
  }
  // i < n, and the index is a byte.
  while i < n {
    c = table.unsafe_get(
        ((c ^ data.unsafe_get(i).to_uint()) & 0xFF).reinterpret_as_int(),
      ) ^
      (c >> 8)
    i += 1
  }
  c ^ 0xFFFFFFFF
}
