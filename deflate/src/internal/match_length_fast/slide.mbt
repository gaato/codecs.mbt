// Generated from parts/match_length_fast/slide.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// The match finders keep positions in 16 bits, as offsets from a base that
// moves up 32 KiB at a time; each move rewrites their tables, 128K entries
// for the hash-chain finder. On Wasm that took a tenth of compressing the
// benchmarks' text at level 6, and eight lanes at a time (libdeflate's
// saturating add) took it 6% faster; on JS the loop without index checks
// took it 6% faster (bench/, 2026-11-19). Native keeps the plain loop, which
// GCC vectorizes: C refuses the cast of an Int16 array to bytes that the
// eight-lane loads need. It is here, with the other SIMD of the match
// finders, because core's @v128 is experimental.

///|
/// Moves every position of `table` 32 KiB down: each `v` becomes
/// `max(v, 0) - 32768`, so that those that fall out of reach become -32768.
#cfg(target="wasm")
pub fn slide(table : FixedArray[Int16]) -> Unit {
  // v + (-32768) saturated is v - 32768 for v >= 0, and -32768 below.
  let bytes = int16s_as_bytes(table)
  let whole = table.length() / 8 * 8
  let down = @v128.i16x8_splat(0x8000)
  let mut i = 0
  while i < whole {
    @v128.v128_store(
      bytes,
      2 * i,
      @v128.i16x8_add_sat_s(@v128.v128_load(bytes, 2 * i), down),
    )
    i += 8
  }
  for j in whole..<table.length() {
    table.unsafe_set(j, slide_one(table.unsafe_get(j)))
  }
}

///|
/// The array's bytes: on Wasm an array's elements lie in linear memory one
/// after another, and the loads and stores above stay within its
/// `2 * length` bytes.
#cfg(target="wasm")
fn int16s_as_bytes(table : FixedArray[Int16]) -> FixedArray[Byte] = "%identity"

///|
/// Moves every position of `table` 32 KiB down, as above, one at a time.
#cfg(not(target="wasm"))
pub fn slide(table : FixedArray[Int16]) -> Unit {
  for i in 0..<table.length() {
    table.unsafe_set(i, slide_one(table.unsafe_get(i)))
  }
}

///|
/// One position moved 32 KiB down, without a branch.
fn slide_one(v : Int16) -> Int16 {
  Int16::from_int(v.to_int().max(0) - 32768)
}
