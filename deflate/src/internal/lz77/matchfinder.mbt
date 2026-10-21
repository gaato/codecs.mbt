// Generated from parts/lz77/matchfinder.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// What the match finders `HcMatchfinder` and `HtMatchfinder` share, after
// libdeflate's matchfinder_common.h: positions kept in 16 bits as offsets
// from a base that moves up 32 KiB at a time, the four bytes they hash, and
// the length of a match.
//
// The finders work on a buffer of the caller's: a position is an index into
// it. When the caller moves its bytes down, it says so (`move_down`), and the
// finders shift their base with them, so that what they find depends only on
// the bytes, never on where the buffer holds them.

///|
/// How far back a match may reach: RFC 1951's 32 KiB window. A match found
/// is at most this minus one back.
pub const WINDOW : Int32 = 32768

///|
/// The bytes a finder needs from a position to search there, or to insert
/// it: four to hash, and one more for the next position's hash.
pub const REQUIRED_BYTES : Int32 = 5

///|
/// A stored position that is out of reach whatever the current one.
const NO_POSITION : Int16 = -32768

///|
/// `data[pos..pos + 4)`, read little-endian, in one load: native and Wasm
/// read four bytes at once, unchecked. Every read of the finders stays
/// before the `in_end` the caller gives (each says why), and the caller's
/// `in_end` is within `data`. The finders ran 10 to 45% faster on native and
/// Wasm with these loads, and slower on JS and Wasm GC, which read each byte
/// (bench/, 2026-10-21).
#cfg(any(target="native", target="wasm"))
#inline
fn load_u32(data : FixedArray[Byte], pos : Int32) -> UInt32 {
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint32_le(pos)
}

///|
/// `data[pos..pos + 4)`, read little-endian, a byte at a time.
#cfg(not(any(target="native", target="wasm")))
#inline
fn load_u32(data : FixedArray[Byte], pos : Int32) -> UInt32 {
  data[pos].to_uint() |
  (data[pos + 1].to_uint() << 8) |
  (data[pos + 2].to_uint() << 16) |
  (data[pos + 3].to_uint() << 24)
}

///|
/// The hash of `seq` in `bits` bits, with `hash4`'s multiplier.
#inline
fn hash_bits(seq : UInt32, bits : Int32) -> Int32 {
  ((seq * HASH_MULTIPLIER) >> (32 - bits)).reinterpret_as_int()
}

///|
/// Whether the candidate at `m` may match the bytes at `in_next` for longer
/// than `best_len` (at least 4): the bytes `best_len - 3` to `best_len` and
/// the first four both match, four at a time. A test that libdeflate makes
/// with fast unaligned loads; it lets through the same longer matches as
/// the byte-wise one. Reads before `in_next + best_len + 1`.
#cfg(any(target="native", target="wasm"))
#inline
fn may_beat(
  data : FixedArray[Byte],
  m : Int32,
  in_next : Int32,
  best_len : Int32,
) -> Bool {
  load_u32(data, m + best_len - 3) == load_u32(data, in_next + best_len - 3) &&
  load_u32(data, m) == load_u32(data, in_next)
}

///|
/// Whether the candidate at `m` may match the bytes at `in_next` for longer
/// than `best_len`: byte `best_len` and the first byte both match, as
/// libdeflate tests without fast unaligned loads.
#cfg(not(any(target="native", target="wasm")))
#inline
fn may_beat(
  data : FixedArray[Byte],
  m : Int32,
  in_next : Int32,
  best_len : Int32,
) -> Bool {
  data[m + best_len] == data[in_next + best_len] && data[m] == data[in_next]
}

///|
/// How many bytes from `a` equal those from `b`, counting from `start`
/// (which the caller knows to match) up to at most `max_len`: four at a
/// time, then byte by byte. Reads before `a + max_len` and `b + max_len`.
#cfg(any(target="native", target="wasm"))
#inline
fn extend_match(
  data : FixedArray[Byte],
  a : Int32,
  b : Int32,
  start : Int32,
  max_len : Int32,
) -> Int32 {
  let mut len = start
  while len + 4 <= max_len {
    let x = load_u32(data, a + len) ^ load_u32(data, b + len)
    if x != 0 {
      return len + (x.ctz() >> 3)
    }
    len += 4
  }
  while len < max_len && data[a + len] == data[b + len] {
    len += 1
  }
  len
}

///|
/// How many bytes from `a` equal those from `b`, counting from `start`
/// (which the caller knows to match) up to at most `max_len`.
#cfg(not(any(target="native", target="wasm")))
#inline
fn extend_match(
  data : FixedArray[Byte],
  a : Int32,
  b : Int32,
  start : Int32,
  max_len : Int32,
) -> Int32 {
  let mut len = start
  while len < max_len && data[a + len] == data[b + len] {
    len += 1
  }
  len
}

///|
/// Moves every stored position of `table` 32 KiB down, as the base moves up:
/// those that fall out of reach become `NO_POSITION`.
fn rebase(table : FixedArray[Int16]) -> Unit {
  for i in 0..<table.length() {
    let v = table[i].to_int()
    table[i] = if v >= 0 { Int16::from_int(v - WINDOW) } else { NO_POSITION }
  }
}
