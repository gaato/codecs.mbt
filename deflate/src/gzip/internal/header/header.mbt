///|
/// FLG bits (RFC 1952 section 2.3.1): the data is probably text.
pub const FTEXT : Int32 = 1

///|
/// A CRC-16 of the header follows its other fields.
pub const FHCRC : Int32 = 2

///|
/// An extra field follows the fixed part: a 2-byte length, then the bytes.
pub const FEXTRA : Int32 = 4

///|
/// A zero-terminated file name follows.
pub const FNAME : Int32 = 8

///|
/// A zero-terminated comment follows.
pub const FCOMMENT : Int32 = 16

///|
/// The size of the fixed part of a header: ID1, ID2, CM, FLG, MTIME, XFL, OS.
pub const FIXED_SIZE : Int32 = 10

///|
/// The fixed part of a member's header.
pub(all) struct Fixed {
  flags : Int32
  mtime : UInt32
  xfl : Byte
  os : Byte
} derive(Eq, @debug.Debug)

///|
/// Whether `start`, the first one or two bytes after a member, can begin
/// another member: ID1 and ID2 are 0x1f and 0x8b.
pub fn begins_member(start : BytesView) -> Bool {
  start.length() >= 1 &&
  start[0] == b'\x1f' &&
  (start.length() == 1 || start[1] == b'\x8b')
}

///|
/// The bytes of a header that `check_start` judges: ID1, ID2, CM and FLG.
pub const START_SIZE : Int32 = 4

///|
/// Checks the first `START_SIZE` bytes of a header, as zlib does before it
/// reads more: the magic number, the compression method (8, DEFLATE, is the
/// only one) and the flags, none of the reserved ones set.
pub fn check_start(b : BytesView) -> Result[Unit, String] {
  if b[0] != b'\x1f' || b[1] != b'\x8b' {
    return Err("not a gzip stream (the magic number is not 1f 8b)")
  }
  if b[2] != b'\x08' {
    return Err("compression method \{b[2].to_int()} is not DEFLATE (8)")
  }
  let flags = b[3].to_int()
  if (flags & 0xE0) != 0 {
    return Err("reserved header flags are set (FLG \{flags})")
  }
  Ok(())
}

///|
/// Reads the fixed part of a header, `FIXED_SIZE` bytes, checking its start
/// as `check_start` does.
pub fn parse_fixed(b : BytesView) -> Result[Fixed, String] {
  if check_start(b[0:START_SIZE]) is Err(message) {
    return Err(message)
  }
  Ok({ flags: b[3].to_int(), mtime: le32(b[4:8]), xfl: b[8], os: b[9], })
}

///|
/// The little-endian value of two bytes: XLEN, or a header's CRC-16.
pub fn le16(b : BytesView) -> Int32 {
  b[0].to_int() | (b[1].to_int() << 8)
}

///|
/// The little-endian value of four bytes.
pub fn le32(b : BytesView) -> UInt32 {
  b[0].to_uint() |
  (b[1].to_uint() << 8) |
  (b[2].to_uint() << 16) |
  (b[3].to_uint() << 24)
}

///|
/// Checks a header's CRC-16, two bytes, against `crc`: the CRC-32 of the
/// header bytes before it, whose low 16 bits it holds.
pub fn check_header_crc(crc : UInt32, b : BytesView) -> Result[Unit, String] {
  if le16(b).reinterpret_as_uint() != (crc & 0xFFFF) {
    return Err("the header's CRC-16 (FHCRC) does not match the header")
  }
  Ok(())
}

///|
/// Checks the first half of a member's trailer, CRC32, 4 bytes, against
/// `crc`, the CRC-32 of the data. zlib checks it before it reads ISIZE.
pub fn check_crc(crc : UInt32, b : BytesView) -> Result[Unit, String] {
  if le32(b) != crc {
    return Err("the CRC-32 of the data does not match the member's")
  }
  Ok(())
}

///|
/// Checks the second half of a member's trailer, ISIZE, 4 bytes, against
/// `size`, the length of the data modulo 2^32.
pub fn check_size(size : UInt32, b : BytesView) -> Result[Unit, String] {
  if le32(b) != size {
    return Err("the length of the data does not match the member's (ISIZE)")
  }
  Ok(())
}

///|
pub extend Fixed with Eq::{equal, not_equal}

///|
pub extend Fixed with @debug.Debug::{to_repr}
