///|
/// ZSTD_hash4..8 multipliers. The width is selected at construction.
#cfg(any(target="native", target="wasm"))
fn hash_prime(width : Int32) -> UInt64 {
  match width {
    4 => 2654435761UL
    5 => 889523592379UL
    6 => 227718039650203UL
    7 => 58295818150454627UL
    _ => 0xcf1bbcdcb7a56463UL
  }
}

///|
/// Caller guarantees 0 <= p and p + 8 <= the valid data end.
#cfg(any(target="native", target="wasm"))
#inline
fn load64(data : FixedArray[Byte], p : Int32) -> UInt64 {
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint64_le(p)
}

///|
/// Caller guarantees 0 <= p and p + 4 <= the valid data end.
#cfg(any(target="native", target="wasm"))
#inline
fn load32(data : FixedArray[Byte], p : Int32) -> UInt32 {
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint32_le(p)
}

///|
/// Each caller supplies the index's range argument at the access site.
#cfg(any(target="native", target="wasm"))
#inline
fn[T] read(data : FixedArray[T], i : Int32) -> T {
  data.unsafe_get(i)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn[T] read(data : FixedArray[T], i : Int32) -> T {
  data[i]
}

///|
/// Each caller supplies the index's range argument at the access site.
#cfg(any(target="native", target="wasm"))
#inline
fn[T] write(data : FixedArray[T], i : Int32, value : T) -> Unit {
  data.unsafe_set(i, value)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn[T] write(data : FixedArray[T], i : Int32, value : T) -> Unit {
  data[i] = value
}

///|
/// Caller has checked 0 <= q < p <= end <= data.length().
#cfg(any(target="native", target="wasm"))
fn match_length(
  data : FixedArray[Byte],
  p : Int32,
  q : Int32,
  end : Int32,
) -> Int32 {
  @match_length_fast.length(data, p, q, end)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn match_length(
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

///|
/// The four bytes ending at the current best length must agree before
/// recounting a chain candidate. search stops when best reaches end - p.
#cfg(any(target="native", target="wasm"))
#inline
fn may_beat(
  data : FixedArray[Byte],
  p : Int32,
  q : Int32,
  best : Int32,
) -> Bool {
  // best >= 3, p + best < end, and 0 <= q < p: both reads fit.
  load32(data, q + best - 3) == load32(data, p + best - 3)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn may_beat(
  data : FixedArray[Byte],
  p : Int32,
  q : Int32,
  best : Int32,
) -> Bool {
  let tail = best - 3
  data[q + tail] == data[p + tail] &&
  data[q + tail + 1] == data[p + tail + 1] &&
  data[q + tail + 2] == data[p + tail + 2] &&
  data[q + tail + 3] == data[p + tail + 3]
}
