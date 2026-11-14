// Bit readers over a buffered block. FSE and Huffman streams are read
// backwards from their end mark (RFC 8878 section 4.1); table descriptions
// are read forwards. Both read little-endian values.

///|
/// `len` bits of `data` starting at bit `lo` from `start`, least significant
/// first. `len` is at most 24 and may be zero; the caller keeps every bit it
/// reads inside the stream.
#inline
fn bits_at(
  data : FixedArray[Byte],
  start : Int32,
  lo : Int32,
  len : Int32,
) -> Int32 {
  let i = start + (lo >> 3)
  // Four bytes hold the at most 7 + 24 bits: one load, no branch on how
  // many bytes the bits span. A zero `len` masks everything off.
  if i >= 0 && i + 4 <= data.length() {
    ((load32(data, i) >> (lo & 7)) & ((1U << len) - 1)).reinterpret_as_int()
  } else {
    bits_near_end(data, start, lo, len)
  }
}

///|
/// `bits_at` within the last three bytes of `data`, a byte at a time.
fn bits_near_end(
  data : FixedArray[Byte],
  start : Int32,
  lo : Int32,
  len : Int32,
) -> Int32 {
  guard len > 0 else { return 0 }
  let i = start + (lo >> 3)
  let shift = lo & 7
  let mut v = data[i].to_uint()
  let last = start + ((lo + len - 1) >> 3)
  if last > i {
    v = v | (data[i + 1].to_uint() << 8)
    if last > i + 1 {
      // Fewer than four bytes are left from i (else `bits_at` reads them
      // at once), and the bits are within them.
      v = v | (data[i + 2].to_uint() << 16)
    }
  }
  ((v >> shift) & ((1U << len) - 1)).reinterpret_as_int()
}

///|
/// A stream read backwards: `pos` bits are left before the read position.
/// Reads past the start give zero bits and make `pos` negative, which the
/// caller treats as corruption once the stream should be used up.
priv struct BackwardBits {
  data : FixedArray[Byte]
  start : Int32
  mut pos : Int32
}

///|
/// The stream in `data[start:end]`, positioned after its end mark: the
/// highest set bit of the last byte.
fn BackwardBits::new(
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
) -> BackwardBits raise Stop {
  if end <= start {
    raise corrupt("an empty bitstream")
  }
  let last = data[end - 1]
  if last == 0 {
    raise corrupt("a bitstream without its end mark")
  }
  let pos = (end - start - 1) * 8 + (31 - last.to_int().clz())
  { data, start, pos, }
}

///|
/// The next `n` (at most 24) bits without consuming them.
#inline
fn BackwardBits::peek(self : BackwardBits, n : Int32) -> Int32 {
  let lo = self.pos - n
  if lo >= 0 {
    bits_at(self.data, self.start, lo, n)
  } else if self.pos <= 0 {
    0
  } else {
    bits_at(self.data, self.start, 0, self.pos) << -lo
  }
}

///|
/// The next `n` (at most 24) bits.
#inline
fn BackwardBits::read(self : BackwardBits, n : Int32) -> Int32 {
  let v = self.peek(n)
  self.pos -= n
  v
}

///|
/// `BackwardBits::peek(n)` of a stream in `data` from `start` with `pos`
/// bits left, for loops that keep `pos` in a local. The common case, bits
/// at or after the stream's start and four bytes before the end of `data`,
/// is written out here so that it is inlined into those loops.
#inline
fn back_bits(
  data : FixedArray[Byte],
  start : Int32,
  pos : Int32,
  n : Int32,
) -> Int32 {
  let lo = pos - n
  let i = start + (lo >> 3)
  if lo >= 0 && i + 4 <= data.length() {
    ((load32(data, i) >> (lo & 7)) & ((1U << n) - 1)).reinterpret_as_int()
  } else {
    back_bits_edge(data, start, pos, n)
  }
}

///|
/// `back_bits` near either end of the stream.
fn back_bits_edge(
  data : FixedArray[Byte],
  start : Int32,
  pos : Int32,
  n : Int32,
) -> Int32 {
  let lo = pos - n
  if lo >= 0 {
    bits_at(data, start, lo, n)
  } else if pos <= 0 {
    0
  } else {
    bits_at(data, start, 0, pos) << -lo
  }
}

///|
/// A stream read forwards, `pos` bits after `start`, ending at `end`.
priv struct ForwardBits {
  data : FixedArray[Byte]
  start : Int32
  end : Int32
  mut pos : Int32
}

///|
fn ForwardBits::new(
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
) -> ForwardBits {
  { data, start, end, pos: 0, }
}

///|
/// The next `n` (at most 16) bits without consuming them; bits past `end`
/// read as zero, as in the reference decoder.
fn ForwardBits::peek(self : ForwardBits, n : Int32) -> Int32 {
  let total = (self.end - self.start) * 8
  if self.pos + n <= total {
    bits_at(self.data, self.start, self.pos, n)
  } else if self.pos >= total {
    0
  } else {
    bits_at(self.data, self.start, self.pos, total - self.pos)
  }
}

///|
fn ForwardBits::read(self : ForwardBits, n : Int32) -> Int32 {
  let v = self.peek(n)
  self.pos += n
  v
}

///|
/// Whether the reads so far stayed within `end`.
fn ForwardBits::in_bounds(self : ForwardBits) -> Bool {
  self.pos <= (self.end - self.start) * 8
}

///|
/// Whole bytes used so far.
fn ForwardBits::bytes_used(self : ForwardBits) -> Int32 {
  (self.pos + 7) >> 3
}

///|
/// The four bytes at `i`, little-endian; the caller has checked
/// `0 <= i` and `i + 4 <= data.length()`.
#cfg(any(target="native", target="wasm"))
#inline
fn load32(data : FixedArray[Byte], i : Int32) -> UInt32 {
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint32_le(i)
}

///|
/// The four bytes at `i`, little-endian; the caller has checked
/// `0 <= i` and `i + 4 <= data.length()`.
#cfg(not(any(target="native", target="wasm")))
fn load32(data : FixedArray[Byte], i : Int32) -> UInt32 {
  data.unsafe_get(i).to_uint() |
  (data.unsafe_get(i + 1).to_uint() << 8) |
  (data.unsafe_get(i + 2).to_uint() << 16) |
  (data.unsafe_get(i + 3).to_uint() << 24)
}

///|
/// Whether `top_bits` may read at `pos`: at least 57 bits after the
/// stream's start. Never on JS, where 64-bit integers are slow.
#cfg(not(target="js"))
#inline
fn wide_reads(pos : Int32) -> Bool {
  pos >= 57
}

///|
#cfg(target="js")
#inline
fn wide_reads(_pos : Int32) -> Bool {
  false
}

///|
/// The bits before `pos` of the stream in `data` from `start`, the last of
/// them (bit `pos - 1`) as the top bit: at least 57 valid bits, for
/// `pos >= 57`. The eight bytes loaded end with the byte of bit `pos - 1`,
/// which is within the stream.
#inline
fn top_bits(data : FixedArray[Byte], start : Int32, pos : Int32) -> UInt64 {
  let q = pos - 57
  let k = start + (q >> 3)
  load64(data, k) << (7 - (q & 7))
}

///|
/// The top `n` (at most 31) bits of `w`: none when `n` is 0.
#inline
fn take_bits(w : UInt64, n : Int32) -> Int32 {
  (w >> 1 >> (63 - n)).to_int()
}

///|
/// The eight bytes at `i`, little-endian; the caller has checked
/// `0 <= i` and `i + 8 <= data.length()`.
#cfg(any(target="native", target="wasm"))
#inline
fn load64(data : FixedArray[Byte], i : Int32) -> UInt64 {
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint64_le(i)
}

///|
#cfg(not(any(target="native", target="wasm")))
fn load64(data : FixedArray[Byte], i : Int32) -> UInt64 {
  load32(data, i).to_uint64() | (load32(data, i + 4).to_uint64() << 32)
}
