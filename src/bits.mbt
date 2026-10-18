// Bit readers over a buffered block. FSE and Huffman streams are read
// backwards from their end mark (RFC 8878 section 4.1); table descriptions
// are read forwards. Both read little-endian values.

///|
/// `len` bits of `data` starting at bit `lo` from `start`, least significant
/// first. `len` is at most 24 and may be zero; the caller keeps every bit it
/// reads inside the stream.
fn bits_at(
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
      v = v | (data[i + 2].to_uint() << 16)
      if last > i + 2 {
        v = v | (data[i + 3].to_uint() << 24)
      }
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
fn BackwardBits::skip(self : BackwardBits, n : Int32) -> Unit {
  self.pos -= n
}

///|
/// The next `n` (at most 24) bits.
fn BackwardBits::read(self : BackwardBits, n : Int32) -> Int32 {
  let v = self.peek(n)
  self.pos -= n
  v
}

///|
/// The next `n` (at most 30) bits.
fn BackwardBits::read_long(self : BackwardBits, n : Int32) -> Int32 {
  if n <= 24 {
    self.read(n)
  } else {
    let high = self.read(n - 16)
    (high << 16) | self.read(16)
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
