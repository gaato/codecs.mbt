// The encoder's bit writer: bits are packed least significant first (RFC
// 7932 section 2) into a byte buffer that the encoder hands out.

///|
priv struct BitPacker {
  mut buf : FixedArray[Byte]
  // Complete bytes in `buf`.
  mut len : Int32
  // `nbits` (below 8 between writes) bits not yet in `buf`.
  mut acc : UInt64
  mut nbits : Int32
}

///|
fn BitPacker::new() -> BitPacker {
  { buf: FixedArray::make(0, b'\x00'), len: 0, acc: 0, nbits: 0, }
}

///|
/// Makes room for `n` more bytes.
fn BitPacker::reserve(self : BitPacker, n : Int32) -> Unit {
  let need = self.len + n
  guard need > self.buf.length() else { return }
  let grown = FixedArray::make(need.max(self.buf.length() * 2), b'\x00')
  FixedArray::unsafe_blit(grown, 0, self.buf, 0, self.len)
  self.buf = grown
}

///|
/// Writes the low `n` (at most 32) bits of `value`.
fn BitPacker::write(self : BitPacker, n : Int32, value : Int32) -> Unit {
  self.acc = self.acc | (value.reinterpret_as_uint().to_uint64() << self.nbits)
  self.nbits += n
  if self.nbits >= 8 {
    self.reserve(5)
    while self.nbits >= 8 {
      self.buf[self.len] = self.acc.to_byte()
      self.len += 1
      self.acc = self.acc >> 8
      self.nbits -= 8
    }
  }
}

///|
/// Pads with zero bits to the next byte boundary.
fn BitPacker::align(self : BitPacker) -> Unit {
  if self.nbits > 0 {
    self.write(8 - self.nbits, 0)
  }
}

///|
/// Appends `n` bytes of `data` from `start`; the writer is byte-aligned.
fn BitPacker::write_bytes(
  self : BitPacker,
  data : FixedArray[Byte],
  start : Int32,
  n : Int32,
) -> Unit {
  self.reserve(n)
  FixedArray::unsafe_blit(self.buf, self.len, data, start, n)
  self.len += n
}

///|
/// Bits written since the buffer was last emptied.
fn BitPacker::position(self : BitPacker) -> Int32 {
  self.len * 8 + self.nbits
}

///|
/// Goes back to `position`, which is at most one partial byte before the
/// buffer's end at the time: those bits are kept in `acc`.
fn BitPacker::rewind(self : BitPacker, position : Int32, acc : UInt64) -> Unit {
  self.len = position / 8
  self.nbits = position % 8
  self.acc = acc
}

///|
/// Empties the buffer of complete bytes, keeping the partial byte.
fn BitPacker::clear(self : BitPacker) -> Unit {
  self.len = 0
}
