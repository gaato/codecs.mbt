///|
/// CRC-32 (CRC-32/ISO-HDLC): gzip's, zlib's `crc32`, PNG's, Ethernet's.
pub let crc32 : Crc = Crc::new(
  width=32,
  poly=0x04C11DB7,
  init=0xFFFFFFFF,
  reflect_in=true,
  xor_out=0xFFFFFFFF,
)

///|
/// CRC-32C (CRC-32/ISCSI, Castagnoli's): Snappy's framing format's, iSCSI's,
/// SCTP's, ext4's and Btrfs's.
pub let crc32c : Crc = Crc::new(
  width=32,
  poly=0x1EDC6F41,
  init=0xFFFFFFFF,
  reflect_in=true,
  xor_out=0xFFFFFFFF,
)

///|
/// CRC-64/XZ (ECMA-182's polynomial, reflected): xz's and Go's
/// `crc64.ECMA`.
pub let crc64_xz : Crc = Crc::new(
  width=64,
  poly=0x42F0E1EBA9EA3693,
  init=0xFFFFFFFFFFFFFFFF,
  reflect_in=true,
  xor_out=0xFFFFFFFFFFFFFFFF,
)

///|
/// The CRC-32 of the data so far, `crc` (0 for none), extended by `data`,
/// eight bytes at a time, as zlib's `crc32(crc, buf, len)` computes it.
pub fn crc32_update(crc : UInt32, data : BytesView) -> UInt32 {
  @crc32.update_bytes(crc, data)
}

///|
/// The CRC-32C of the data so far, `crc` (0 for none), extended by `data`,
/// eight bytes at a time.
pub fn crc32c_update(crc : UInt32, data : BytesView) -> UInt32 {
  @crc32c.update_bytes(crc, data)
}

///|
/// The reflected polynomial of CRC-64/XZ.
const CRC64_XZ_REFLECTED : UInt64 = 0xC96C5795D7870F42

///|
/// The CRC-64/XZ of every byte value.
let crc64_table : FixedArray[UInt64] = FixedArray::makei(256, n => {
  let mut c = n.to_uint64()
  for _ in 0..<8 {
    c = if (c & 1) != 0 { CRC64_XZ_REFLECTED ^ (c >> 1) } else { c >> 1 }
  }
  c
})

///|
/// The tables of slice-by-8, 16 KiB: entry `k * 256 + n` is the CRC-64/XZ
/// of byte `n` followed by `k` zero bytes.
let crc64_tables : FixedArray[UInt64] = FixedArray::makei(8 * 256, i => {
  let mut c = crc64_table[i % 256]
  for _ in 0..<(i / 256) {
    c = crc64_table[(c & 0xFF).to_int()] ^ (c >> 8)
  }
  c
})

///|
/// The CRC-64/XZ of the data so far, `crc` (0 for none), extended by
/// `data`, eight bytes at a time, as xz's `lzma_crc64` computes it.
pub fn crc64_xz_update(crc : UInt64, data : BytesView) -> UInt64 {
  let t = crc64_tables
  let mut c = crc.lnot()
  let n = data.length()
  let mut i = 0
  // i + 7 < n: the eight reads are within `data`; each index is k * 256
  // plus a byte, k < 8, within the 2,048 entries.
  while n - i >= 8 {
    let x = c ^
      (
        data.unsafe_get(i).to_uint64() |
        (data.unsafe_get(i + 1).to_uint64() << 8) |
        (data.unsafe_get(i + 2).to_uint64() << 16) |
        (data.unsafe_get(i + 3).to_uint64() << 24) |
        (data.unsafe_get(i + 4).to_uint64() << 32) |
        (data.unsafe_get(i + 5).to_uint64() << 40) |
        (data.unsafe_get(i + 6).to_uint64() << 48) |
        (data.unsafe_get(i + 7).to_uint64() << 56)
      )
    c = t.unsafe_get(7 * 256 + (x & 0xFF).to_int()) ^
      t.unsafe_get(6 * 256 + ((x >> 8) & 0xFF).to_int()) ^
      t.unsafe_get(5 * 256 + ((x >> 16) & 0xFF).to_int()) ^
      t.unsafe_get(4 * 256 + ((x >> 24) & 0xFF).to_int()) ^
      t.unsafe_get(3 * 256 + ((x >> 32) & 0xFF).to_int()) ^
      t.unsafe_get(2 * 256 + ((x >> 40) & 0xFF).to_int()) ^
      t.unsafe_get(256 + ((x >> 48) & 0xFF).to_int()) ^
      t.unsafe_get((x >> 56).to_int())
    i += 8
  }
  // i < n, and the index is a byte.
  while i < n {
    c = crc64_table.unsafe_get(
        ((c ^ data.unsafe_get(i).to_uint64()) & 0xFF).to_int(),
      ) ^
      (c >> 8)
    i += 1
  }
  c.lnot()
}
