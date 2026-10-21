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
/// The CRC-32 of no data.
pub const INITIAL : UInt32 = 0

///|
/// The CRC-32 of the data so far, `crc`, extended by `data`.
pub fn update(crc : UInt32, data : ArrayView[Byte]) -> UInt32 {
  let mut c = crc ^ 0xFFFFFFFF
  for byte in data {
    c = table[((c ^ byte.to_uint()) & 0xFF).reinterpret_as_int()] ^ (c >> 8)
  }
  c ^ 0xFFFFFFFF
}

///|
/// The CRC-32 of the data so far, `crc`, extended by `data`.
pub fn update_bytes(crc : UInt32, data : BytesView) -> UInt32 {
  let mut c = crc ^ 0xFFFFFFFF
  for byte in data {
    c = table[((c ^ byte.to_uint()) & 0xFF).reinterpret_as_int()] ^ (c >> 8)
  }
  c ^ 0xFFFFFFFF
}
