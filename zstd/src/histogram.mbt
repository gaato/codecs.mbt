// Byte counts of a block's literals, in one pass: the whole block's and
// those of the four streams it may be split into.
//
// Each step counts one byte of each of the four streams into that
// stream's own table, as zstd's HIST_count_parallel spreads its counts
// over four tables: consecutive increments go to different tables, so a
// run of one byte value does not make each increment wait for the store
// of the one before. Native and Wasm read four bytes of each stream at
// once, unchecked; JS and Wasm GC read byte by byte, checked.

///|
/// Counts `data[start:start + len]`, `len` at least 4, into `quarters`,
/// the stream of `HuffmanEncoder::write_literals` each byte goes to, and
/// their sum into `counts`. Every table has 256 entries.
fn count_quarters(
  data : FixedArray[Byte],
  start : Int32,
  len : Int32,
  counts : FixedArray[Int32],
  quarters : FixedArray[FixedArray[Int32]],
) -> Unit {
  let c0 = quarters[0]
  let c1 = quarters[1]
  let c2 = quarters[2]
  let c3 = quarters[3]
  c0.fill(0)
  c1.fill(0)
  c2.fill(0)
  c3.fill(0)
  // Three streams of `segment` bytes and a last one of `last`, at least 1
  // byte since len >= 4, and at most `segment`.
  let segment = (len + 3) / 4
  let last = len - 3 * segment
  let a = start
  let b = a + segment
  let c = b + segment
  let d = c + segment
  let j = count_four(data, a, b, c, d, last, c0, c1, c2, c3)
  for k in j..<last {
    // k < last <= segment: each stream has byte k.
    bump(c0, data[a + k])
    bump(c1, data[b + k])
    bump(c2, data[c + k])
    bump(c3, data[d + k])
  }
  for k in last..<segment {
    // last <= k < segment: only the first three streams have byte k.
    bump(c0, data[a + k])
    bump(c1, data[b + k])
    bump(c2, data[c + k])
  }
  for s in 0..<256 {
    counts[s] = c0[s] + c1[s] + c2[s] + c3[s]
  }
}

///|
/// Counts bytes 0 to some j <= n - (n % 4) of the streams at a, b, c and d
/// four at a time; returns j for the caller to count the rest.
#cfg(any(target="native", target="wasm"))
fn count_four(
  data : FixedArray[Byte],
  a : Int32,
  b : Int32,
  c : Int32,
  d : Int32,
  n : Int32,
  c0 : FixedArray[Int32],
  c1 : FixedArray[Int32],
  c2 : FixedArray[Int32],
  c3 : FixedArray[Int32],
) -> Int32 {
  let bytes = data.unsafe_reinterpret_as_bytes()
  let mut j = 0
  while j + 4 <= n {
    // j + 4 <= n <= every stream's length, and the streams lie within the
    // caller's range of `data`: the four loads read valid bytes.
    let wa = bytes.unsafe_read_uint32_le(a + j)
    let wb = bytes.unsafe_read_uint32_le(b + j)
    let wc = bytes.unsafe_read_uint32_le(c + j)
    let wd = bytes.unsafe_read_uint32_le(d + j)
    bump_word(c0, c1, c2, c3, wa, wb, wc, wd, 0)
    bump_word(c0, c1, c2, c3, wa, wb, wc, wd, 8)
    bump_word(c0, c1, c2, c3, wa, wb, wc, wd, 16)
    bump_word(c0, c1, c2, c3, wa, wb, wc, wd, 24)
    j += 4
  }
  j
}

///|
/// Counts the byte at `shift` of each stream's word into its table.
#cfg(any(target="native", target="wasm"))
#inline
fn bump_word(
  c0 : FixedArray[Int32],
  c1 : FixedArray[Int32],
  c2 : FixedArray[Int32],
  c3 : FixedArray[Int32],
  wa : UInt32,
  wb : UInt32,
  wc : UInt32,
  wd : UInt32,
  shift : Int32,
) -> Unit {
  bump_index(c0, ((wa >> shift) & 255).reinterpret_as_int())
  bump_index(c1, ((wb >> shift) & 255).reinterpret_as_int())
  bump_index(c2, ((wc >> shift) & 255).reinterpret_as_int())
  bump_index(c3, ((wd >> shift) & 255).reinterpret_as_int())
}

///|
#cfg(not(any(target="native", target="wasm")))
fn count_four(
  _data : FixedArray[Byte],
  _a : Int32,
  _b : Int32,
  _c : Int32,
  _d : Int32,
  _n : Int32,
  _c0 : FixedArray[Int32],
  _c1 : FixedArray[Int32],
  _c2 : FixedArray[Int32],
  _c3 : FixedArray[Int32],
) -> Int32 {
  0
}

///|
/// Adds one to the count of `byte`, in a table of 256.
#inline
fn bump(table : FixedArray[Int32], byte : Byte) -> Unit {
  bump_index(table, byte.to_int())
}

///|
/// Adds one to `table[i]`; the caller's `i` is a byte value, below the
/// table's 256 entries.
#cfg(any(target="native", target="wasm"))
#inline
fn bump_index(table : FixedArray[Int32], i : Int32) -> Unit {
  table.unsafe_set(i, table.unsafe_get(i) + 1)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn bump_index(table : FixedArray[Int32], i : Int32) -> Unit {
  table[i] += 1
}
