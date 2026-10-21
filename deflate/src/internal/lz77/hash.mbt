// Generated from parts/lz77/hash.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// What LZ77 match finders share: the hash of the next bytes, which picks
// where to look for earlier occurrences, and the length of a match found
// there.

///|
/// The multiplier of the hashes: zlib-ng's and libdeflate's.
const HASH_MULTIPLIER : UInt32 = 0x1e35a7bd

///|
/// The hash of `data[pos..pos + 4)`, read little-endian, in `bits` bits (1
/// to 32).
pub fn hash4(data : FixedArray[Byte], pos : Int32, bits : Int32) -> Int32 {
  let v = data[pos].to_uint() |
    (data[pos + 1].to_uint() << 8) |
    (data[pos + 2].to_uint() << 16) |
    (data[pos + 3].to_uint() << 24)
  ((v * HASH_MULTIPLIER) >> (32 - bits)).reinterpret_as_int()
}

///|
/// How many bytes from `a` equal those from `b` (`a < b`), at most `limit`.
pub fn match_length(
  data : FixedArray[Byte],
  a : Int32,
  b : Int32,
  limit : Int32,
) -> Int32 {
  for n = 0; n < limit; n = n + 1 {
    if data[a + n] != data[b + n] {
      return n
    }
  }
  limit
}
