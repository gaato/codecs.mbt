///|
/// Counts equal bytes for 0 <= q < p <= end <= data.length(). Sixteen
/// bytes at a time, then eight, then the last valid bytes individually.
/// SSE2 lowers eq/bitmask to pcmpeqb/pmovmskb; NEON uses vceqq_u8 and
/// a shift/accumulate sequence for the bitmask (moonbit_simd.h).
#cfg(any(target="native", target="wasm"))
pub fn length(
  data : FixedArray[Byte],
  p : Int32,
  q : Int32,
  end : Int32,
) -> Int32 {
  let mut n = 0
  while p + n + 16 <= end {
    // q < p and sixteen bytes remain at p + n: both loads fit valid data.
    let equal = @v128.i8x16_bitmask(
      @v128.i8x16_eq(@v128.v128_load(data, p + n), @v128.v128_load(data, q + n)),
    )
    if equal != 65535 {
      return n + (equal ^ 65535).ctz()
    }
    n += 16
  }
  if p + n + 8 <= end {
    // q < p and eight bytes remain at p + n.
    let bytes = data.unsafe_reinterpret_as_bytes()
    let diff = bytes.unsafe_read_uint64_le(p + n) ^
      bytes.unsafe_read_uint64_le(q + n)
    if diff != 0 {
      return n + (diff.ctz() >> 3)
    }
    n += 8
  }
  // Only valid input is read: p + n < end and 0 <= q < p.
  while p + n < end && data.unsafe_get(p + n) == data.unsafe_get(q + n) {
    n += 1
  }
  n
}

///|
/// Checked reference on targets without efficient SIMD loads.
#cfg(not(any(target="native", target="wasm")))
pub fn length(
  data : FixedArray[Byte],
  p : Int32,
  q : Int32,
  end : Int32,
) -> Int32 {
  let mut n = 0
  while p + n < end && data[p + n] == data[q + n] {
    n += 1
  }
  n
}
