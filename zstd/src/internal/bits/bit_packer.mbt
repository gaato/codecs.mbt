// Generated from parts/bits/bit_packer.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// An encoder's bit writer: bits are packed least significant first (RFC 1951
// section 3.1.1, RFC 7932 section 2) into a byte buffer that the encoder
// hands out with `drain`.
//
// The bits not yet in a byte wait in an accumulator of 64 bits, so that one
// write of up to 32 bits never needs splitting, except on JS: there a 64-bit
// integer is a BigInt, and the brotli encoder ran twice as fast with 32 bits
// and long writes split in two, while native, wasm and wasm-gc ran 0 to 3%
// slower that way (bench/, 2026-10-21).
//
// With 64 bits, up to 31 bits wait between writes, and a write that brings
// them to 32 moves the whole bytes into the buffer in one eight-byte store,
// as zstd's BIT_flushBits does. That took 16% off the Zstandard encoder's
// level-one time on the bench text natively, and 14% off Wasm GC's on the
// binary; moving the bytes after every write instead, one store each time,
// gave back over half of the native gain (zstd/docs/compression.md, Speed).
// JS keeps 32 bits and moves bytes one at a time after each write. Whole
// bytes still in the accumulator are moved before anything counts or hands
// out the buffer's bytes, so `pending`, `drain` and the rest see them.

///|
#cfg(not(target="js"))
type Acc = UInt64

///|
#cfg(target="js")
type Acc = UInt32

///|
/// A bit writer and the bytes it holds for the caller.
pub struct BitPacker {
  priv mut buf : FixedArray[Byte]
  // Complete bytes in `buf`; those from `drained` wait to be handed out.
  priv mut len : Int32
  priv mut drained : Int32
  // `nbits` bits not yet in `buf`: below 8 after `flush`, and between
  // writes below 32, except on JS, where they are below 8.
  priv mut acc : Acc
  priv mut nbits : Int32
}

///|
/// A place in the output to go back to: what `BitPacker::mark` saw.
pub struct Mark {
  priv len : Int32
  priv nbits : Int32
  // The bits not yet in `buf`, as many as `nbits` says.
  priv partial : Acc
}

///|
/// An empty writer; its buffer grows as bits come.
pub fn BitPacker::BitPacker() -> BitPacker {
  { buf: FixedArray::make(0, b'\x00'), len: 0, drained: 0, acc: 0, nbits: 0, }
}

///|
/// Forgets every byte and bit, keeping the buffer's memory.
pub fn BitPacker::reset(self : BitPacker) -> Unit {
  self.len = 0
  self.drained = 0
  self.acc = 0
  self.nbits = 0
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
/// Writes the `n` (at most 32) bits of `value`, which has no bits above them.
#cfg(not(target="js"))
pub fn BitPacker::write(self : BitPacker, n : Int32, value : Int32) -> Unit {
  // Fewer than 32 bits wait, so the 64-bit accumulator holds these too.
  self.acc = self.acc | (value.reinterpret_as_uint().to_uint64() << self.nbits)
  self.nbits += n
  if self.nbits >= FLUSH_AT {
    self.flush()
  }
}

///|
/// Moves the accumulator's whole bytes into the buffer, all of them in one
/// eight-byte store when the buffer has eight bytes of room: the bytes past
/// the whole ones land beyond `len`, where the next store overwrites them
/// and nothing reads them.
#cfg(not(target="js"))
fn BitPacker::flush(self : BitPacker) -> Unit {
  let whole = self.nbits >> 3
  if self.len + 8 <= self.buf.length() {
    // 0 <= len and len + 8 <= buf.length(): the store lies within `buf`.
    self.buf.unsafe_write_uint64_le(self.len, self.acc)
  } else {
    self.reserve(whole)
    for i in 0..<whole {
      self.buf[self.len + i] = (self.acc >> (i << 3)).to_byte()
    }
  }
  self.len += whole
  // At most 63 bits wait, so the shift is below 64.
  self.acc = self.acc >> (whole << 3)
  self.nbits = self.nbits & 7
}

///|
/// Waiting bits that make `write` move whole bytes to the buffer: with
/// fewer than 32 waiting, the 64-bit accumulator takes a write of up to 32.
#cfg(not(target="js"))
const FLUSH_AT : Int32 = 32

///|
/// Moves the accumulator's whole bytes into the buffer, one at a time.
#cfg(target="js")
fn BitPacker::flush(self : BitPacker) -> Unit {
  if self.nbits >= 8 {
    self.reserve(4)
    while self.nbits >= 8 {
      self.buf[self.len] = self.acc.to_byte()
      self.len += 1
      self.acc = self.acc >> 8
      self.nbits -= 8
    }
  }
}

///|
/// Writes the `n` (at most 32) bits of `value`, which has no bits above them.
#cfg(target="js")
pub fn BitPacker::write(self : BitPacker, n : Int32, value : Int32) -> Unit {
  if self.nbits + n > 32 {
    // More than the accumulator holds: the low 16 bits first.
    self.write_fitting(16, value & 0xffff)
    self.write_fitting(
      n - 16,
      (value.reinterpret_as_uint() >> 16).reinterpret_as_int(),
    )
  } else {
    self.write_fitting(n, value)
  }
}

///|
/// `write`, when the accumulator holds the `n` bits with those it has.
#cfg(target="js")
fn BitPacker::write_fitting(self : BitPacker, n : Int32, value : Int32) -> Unit {
  self.acc = self.acc | (value.reinterpret_as_uint() << self.nbits)
  self.nbits += n
  self.flush()
}

///|
/// Pads with zero bits to the next byte boundary.
pub fn BitPacker::align(self : BitPacker) -> Unit {
  let partial = self.nbits & 7
  if partial > 0 {
    self.write(8 - partial, 0)
  }
}

///|
/// Ends a Zstandard bitstream, which is read backward from its last byte
/// (RFC 8878 section 4.1): writes a 1 bit, the end mark, and pads with zero
/// bits to the next byte boundary. The reader finds the end mark as the
/// highest set bit of the last byte, so the bits before it are the stream's,
/// with nothing between them and the mark.
pub fn BitPacker::write_end_mark(self : BitPacker) -> Unit {
  self.write(1, 1)
  self.align()
}

///|
/// Whether the bits written so far end on a byte boundary.
pub fn BitPacker::is_aligned(self : BitPacker) -> Bool {
  (self.nbits & 7) == 0
}

///|
/// Appends `n` bytes of `data` from `start`; the writer is byte-aligned.
pub fn BitPacker::write_bytes(
  self : BitPacker,
  data : FixedArray[Byte],
  start : Int32,
  n : Int32,
) -> Unit {
  self.flush()
  self.reserve(n)
  FixedArray::unsafe_blit(self.buf, self.len, data, start, n)
  self.len += n
}

///|
/// Appends the complete bytes `other` waits to hand out and hands them out
/// of it, in one copy; this writer is byte-aligned.
pub fn BitPacker::write_pending(self : BitPacker, other : BitPacker) -> Unit {
  self.flush()
  let n = other.pending()
  self.reserve(n)
  FixedArray::unsafe_blit(self.buf, self.len, other.buf, other.drained, n)
  self.len += n
  other.drained += n
  other.empty_if_drained()
}

///|
/// Bits written since the buffer was last empty.
pub fn BitPacker::position(self : BitPacker) -> Int32 {
  self.len * 8 + self.nbits
}

///|
/// The current place, for `rewind`.
pub fn BitPacker::mark(self : BitPacker) -> Mark {
  { len: self.len, nbits: self.nbits, partial: self.acc, }
}

///|
/// Goes back to `mark`, dropping what was written since. Nothing may have
/// been handed out in between.
pub fn BitPacker::rewind(self : BitPacker, mark : Mark) -> Unit {
  self.len = mark.len
  self.nbits = mark.nbits
  self.acc = mark.partial
}

///|
/// Complete bytes waiting to be handed out.
pub fn BitPacker::pending(self : BitPacker) -> Int32 {
  self.flush()
  self.len - self.drained
}

///|
/// Complete bytes in the buffer, handed out or not, until all are.
pub fn BitPacker::buffered(self : BitPacker) -> Int32 {
  self.flush()
  self.len
}

///|
/// The buffer's size in bytes.
pub fn BitPacker::capacity(self : BitPacker) -> Int32 {
  self.buf.length()
}

///|
/// Hands out waiting bytes into `output` from `pos`, as many as fit; the new
/// position. Once all are handed out the buffer is empty again, keeping the
/// partial byte.
pub fn BitPacker::drain(
  self : BitPacker,
  output : MutArrayView[Byte],
  pos : Int32,
) -> Int32 {
  let n = self.pending().min(output.length() - pos)
  if n > 0 {
    output.blit_from_array(
      self.buf[self.drained:self.drained + n],
      dst_offset=pos,
    )
  }
  self.drained += n
  self.empty_if_drained()
  pos + n
}

///|
/// `drain` into a whole `FixedArray`, with a bulk copy.
pub fn BitPacker::drain_into(
  self : BitPacker,
  output : FixedArray[Byte],
  pos : Int32,
) -> Int32 {
  let n = self.pending().min(output.length() - pos)
  if n > 0 {
    FixedArray::unsafe_blit(output, pos, self.buf, self.drained, n)
  }
  self.drained += n
  self.empty_if_drained()
  pos + n
}

///|
fn BitPacker::empty_if_drained(self : BitPacker) -> Unit {
  if self.drained == self.len {
    self.len = 0
    self.drained = 0
  }
}
