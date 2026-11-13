///|
/// A block's sequences and concatenated literals. Length arrays hold raw
/// lengths; offset storage keeps OffsetValue distinct from raw Distance.
/// Storage grows only to one block (at most floor(128 KiB / 3) sequences).
pub struct Block {
  mut count : Int32
  mut literal_count : Int32
  mut literals : FixedArray[Byte]
  mut ll : FixedArray[Int32]
  mut ml : FixedArray[Int32]
  mut offsets : FixedArray[OffsetValue]
  repeats : Repeats
}

///|
/// Empty sequence storage.
pub fn Block::Block() -> Block {
  {
    count: 0,
    literal_count: 0,
    literals: [],
    ll: [],
    ml: [],
    offsets: [],
    repeats: Repeats(),
  }
}

///|
/// Begins a speculative block with the committed frame's repeat history.
pub fn Block::reset(self : Block, repeats : Repeats, size : Int32) -> Unit {
  self.count = 0
  self.literal_count = 0
  self.repeats.copy_from(repeats)
  if self.literals.length() < size {
    self.literals = FixedArray::make(size, b'\x00')
  }
}

///|
/// Appends a sequence; literals are appended separately with `literal`.
pub fn Block::add(
  self : Block,
  ll : Int32,
  ml : Int32,
  distance : Distance,
) -> Unit {
  if self.count == self.ll.length() {
    let n = (self.count * 2).max(16).min(131072 / 3)
    let ls = FixedArray::make(n, 0)
    let ms = FixedArray::make(n, 0)
    let os = FixedArray::make(n, OffsetValue(0))
    for i in 0..<self.count {
      ls[i] = self.ll[i]
      ms[i] = self.ml[i]
      os[i] = self.offsets[i]
    }
    self.ll = ls
    self.ml = ms
    self.offsets = os
  }
  let value = self.repeats.encode(distance, ll)
  self.ll[self.count] = ll
  self.ml[self.count] = ml
  self.offsets[self.count] = value
  self.count += 1
}

///|
/// Appends a literal in sequence order, at most the original block size.
pub fn Block::literal(self : Block, byte : Byte) -> Unit {
  self.literals[self.literal_count] = byte
  self.literal_count += 1
}

///|
/// Bytes of retained arrays and repeat history.
pub fn Block::memory_usage(self : Block) -> Int32 {
  self.literals.length() + 12 * self.ll.length() + 12
}

///|
/// Code whose baseline is the last one no larger than `value`.
pub fn length_code(value : Int32, bases : FixedArray[Int32]) -> Int32 {
  let mut code = 0
  while code + 1 < bases.length() && bases[code + 1] <= value {
    code += 1
  }
  code
}

///|
/// Offset code and extra field; no signed shift at width 31.
pub fn offset_code(value : OffsetValue) -> (Int32, UInt32) {
  let OffsetValue(v) = value
  let code = 31 - v.clz()
  (code, v - (1U << code))
}

///|
/// Number_of_Sequences in its shortest RFC representation.
pub fn write_count(out : @bits.BitPacker, count : Int32) -> Unit {
  if count < 128 {
    out.write(8, count)
  } else if count < 0x7f00 {
    out.write(8, (count >> 8) + 128)
    out.write(8, count & 255)
  } else {
    out.write(8, 255)
    out.write(16, count - 0x7f00)
  }
}
