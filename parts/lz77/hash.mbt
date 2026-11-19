// What LZ77 match finders share: the hash of the next bytes, which picks
// where to look for earlier occurrences, and the length of a match found
// there.

///|
/// The multiplier of the hashes: zlib-ng's and libdeflate's.
const HASH_MULTIPLIER : UInt32 = 0x1e35a7bd

///|
/// The hash of `data[pos..pos + 4)`, read little-endian, in `bits` bits (1
/// to 32). The caller has checked that the four bytes are within `data`.
pub fn hash4(data : FixedArray[Byte], pos : Int32, bits : Int32) -> Int32 {
  ((load4(data, pos) * HASH_MULTIPLIER) >> (32 - bits)).reinterpret_as_int()
}

///|
/// The four bytes at `pos`, little-endian, in one load: `pos + 4` is within
/// `data` (`hash4`'s callers check it).
#cfg(any(target="native", target="wasm"))
fn load4(data : FixedArray[Byte], pos : Int32) -> UInt32 {
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint32_le(pos)
}

///|
#cfg(not(any(target="native", target="wasm")))
fn load4(data : FixedArray[Byte], pos : Int32) -> UInt32 {
  // hash4's callers leave four bytes starting at pos in data.
  data.unsafe_get(pos).to_uint() |
  (data.unsafe_get(pos + 1).to_uint() << 8) |
  (data.unsafe_get(pos + 2).to_uint() << 16) |
  (data.unsafe_get(pos + 3).to_uint() << 24)
}

///|
/// How many bytes from `a` equal those from `b` (`0 <= a < b`), at most
/// `limit`; `b + limit` is within `data`. Sixteen bytes at a time on native
/// and Wasm (`@match_length_fast`).
pub fn match_length(
  data : FixedArray[Byte],
  a : Int32,
  b : Int32,
  limit : Int32,
) -> Int32 {
  @match_length_fast.length(data, b, a, b + limit)
}

///|
/// `data[i]` without the index check: each caller bounds `i` within `data`.
fn[T] read(data : FixedArray[T], i : Int32) -> T {
  data.unsafe_get(i)
}

///|
/// `data[i] = value`, as `read`: each caller bounds `i` within `data`.
fn[T] write(data : FixedArray[T], i : Int32, value : T) -> Unit {
  data.unsafe_set(i, value)
}
