// Fragment-local bit storage permits q0's in-place meta-block length updates
// without changing the shared writer or the quality-4 path.

///|
priv struct LowBits {
  data : FixedArray[Byte]
  mut pos : Int32
}

///|
fn LowBits::new(bytes : Int32, offset~ : Int32 = 0) -> LowBits {
  { data: FixedArray::make(bytes + 8, b'\x00'), pos: offset, }
}

///|
fn LowBits::write(self : LowBits, n : Int32, value : Int32) -> Unit {
  let mut left = n
  let mut value = value.reinterpret_as_uint()
  while left > 0 {
    let shift = self.pos & 7
    let take = left.min(8 - shift)
    let at = self.pos >> 3
    self.data[at] = (self.data[at].to_uint() |
    ((value & ((1U << take) - 1U)) << shift)).to_byte()
    self.pos += take
    value = value >> take
    left -= take
  }
}

///|
fn LowBits::patch(
  self : LowBits,
  n : Int32,
  value : Int32,
  position : Int32,
) -> Unit {
  let end = self.pos
  self.pos = position
  let mut left = n
  let mut value = value.reinterpret_as_uint()
  while left > 0 {
    let shift = self.pos & 7
    let take = left.min(8 - shift)
    let mask = ((1U << take) - 1U) << shift
    let at = self.pos >> 3
    self.data[at] = ((self.data[at].to_uint() & (0xffffffffU - mask)) |
    ((value << shift) & mask)).to_byte()
    self.pos += take
    value = value >> take
    left -= take
  }
  self.pos = end
}

///|
fn LowBits::rewind(self : LowBits, position : Int32) -> Unit {
  let old_end = (self.pos + 7) >> 3
  let byte = position >> 3
  self.data[byte] = (self.data[byte].to_int() & ((1 << (position & 7)) - 1)).to_byte()
  if byte + 1 < old_end {
    self.data.fill(b'\x00', start=byte + 1, end=old_end)
  }
  self.pos = position
}

///|
fn LowBits::align(self : LowBits) -> Unit {
  self.pos = (self.pos + 7) & -8
}

///|
fn LowBits::bytes(
  self : LowBits,
  data : FixedArray[Byte],
  start : Int32,
  length : Int32,
) -> Unit {
  FixedArray::unsafe_blit(self.data, self.pos >> 3, data, start, length)
  self.pos += 8 * length
}

///|
fn LowBits::header(self : LowBits, length : Int32, raw : Bool) -> Unit {
  let nibbles = if length <= 65536 {
    4
  } else if length <= 1048576 {
    5
  } else {
    6
  }
  self.write(1, 0)
  self.write(2, nibbles - 4)
  self.write(4 * nibbles, length - 1)
  self.write(1, if raw { 1 } else { 0 })
}

///|
fn LowBits::raw(
  self : LowBits,
  data : FixedArray[Byte],
  start : Int32,
  length : Int32,
  position : Int32,
) -> Unit {
  self.rewind(position)
  self.header(length, true)
  self.align()
  self.bytes(data, start, length)
}

///|
fn LowBits::append_to(
  self : LowBits,
  writer : @bits.BitPacker,
  offset : Int32,
) -> Unit {
  let mut p = offset
  if (p & 7) != 0 && p < self.pos {
    let n = (8 - (p & 7)).min(self.pos - p)
    writer.write(n, (self.data[p >> 3].to_int() >> (p & 7)) & ((1 << n) - 1))
    p += n
  }
  let whole = (self.pos - p) >> 3
  if whole > 0 {
    writer.write_bytes(self.data, p >> 3, whole)
    p += 8 * whole
  }
  if p < self.pos {
    writer.write(
      self.pos - p,
      self.data[p >> 3].to_int() & ((1 << (self.pos - p)) - 1),
    )
  }
}

///|
fn LowBits::standard_tree(self : LowBits, depths : FixedArray[Int32]) -> Unit {
  let writer = @bits.BitPacker()
  ref_write_complex(writer, depths)
  let bits = writer.position()
  writer.align()
  let data = FixedArray::make((bits + 7) / 8, b'\x00')
  let _ = writer.drain(data.mut_view(), 0)
  for i in 0..<(bits / 8) {
    self.write(8, data[i].to_int())
  }
  if (bits & 7) != 0 {
    self.write(bits & 7, data[bits / 8].to_int())
  }
}
