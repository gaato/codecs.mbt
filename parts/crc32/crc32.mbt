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
  tables[7 * 256 + (x & 0xFF).reinterpret_as_int()] ^
  tables[6 * 256 + ((x >> 8) & 0xFF).reinterpret_as_int()] ^
  tables[5 * 256 + ((x >> 16) & 0xFF).reinterpret_as_int()] ^
  tables[4 * 256 + (x >> 24).reinterpret_as_int()] ^
  tables[3 * 256 + (hi & 0xFF).reinterpret_as_int()] ^
  tables[2 * 256 + ((hi >> 8) & 0xFF).reinterpret_as_int()] ^
  tables[256 + ((hi >> 16) & 0xFF).reinterpret_as_int()] ^
  tables[(hi >> 24).reinterpret_as_int()]
}

///|
/// The CRC-32 of the data so far, `crc`, extended by `data`.
pub fn update(crc : UInt32, data : ArrayView[Byte]) -> UInt32 {
  let mut c = crc ^ 0xFFFFFFFF
  let n = data.length()
  let mut i = 0
  while i + 8 <= n {
    let lo = data[i].to_uint() |
      (data[i + 1].to_uint() << 8) |
      (data[i + 2].to_uint() << 16) |
      (data[i + 3].to_uint() << 24)
    let hi = data[i + 4].to_uint() |
      (data[i + 5].to_uint() << 8) |
      (data[i + 6].to_uint() << 16) |
      (data[i + 7].to_uint() << 24)
    c = fold8(c, lo, hi)
    i += 8
  }
  for byte in data[i:] {
    c = table[((c ^ byte.to_uint()) & 0xFF).reinterpret_as_int()] ^ (c >> 8)
  }
  c ^ 0xFFFFFFFF
}

///|
/// The CRC-32 of the data so far, `crc`, extended by `data`.
pub fn update_bytes(crc : UInt32, data : BytesView) -> UInt32 {
  let mut c = crc ^ 0xFFFFFFFF
  let n = data.length()
  let mut i = 0
  while i + 8 <= n {
    let lo = data[i].to_uint() |
      (data[i + 1].to_uint() << 8) |
      (data[i + 2].to_uint() << 16) |
      (data[i + 3].to_uint() << 24)
    let hi = data[i + 4].to_uint() |
      (data[i + 5].to_uint() << 8) |
      (data[i + 6].to_uint() << 16) |
      (data[i + 7].to_uint() << 24)
    c = fold8(c, lo, hi)
    i += 8
  }
  for byte in data[i:] {
    c = table[((c ^ byte.to_uint()) & 0xFF).reinterpret_as_int()] ^ (c >> 8)
  }
  c ^ 0xFFFFFFFF
}
