///|
/// A deterministic pseudo-random sequence (a linear congruential
/// generator).
struct Lcg {
  mut state : UInt32
}

///|
/// A number in `0..<bound`.
fn Lcg::below(self : Lcg, bound : Int32) -> Int32 {
  self.state = self.state * 1664525 + 1013904223
  (self.state >> 8).reinterpret_as_int() % bound
}

///|
/// A number of `n` bits (0 to 32).
fn Lcg::bits(self : Lcg, n : Int32) -> Int32 {
  let high = self.below(1 << 16)
  let low = self.below(1 << 16)
  let v = (high << 16) | low
  if n == 32 {
    v
  } else {
    v & ((1 << n) - 1)
  }
}

///|
/// The bytes of the bit sequence `bits`, packed least significant first and
/// padded with zero bits: the packing written out one bit at a time.
fn pack(bits : Array[Bool]) -> Bytes {
  Bytes::makei((bits.length() + 7) / 8, i => {
    for b = 0, byte = 0; b < 8; {
      let set = 8 * i + b < bits.length() && bits[8 * i + b]
      continue b + 1, if set { byte | (1 << b) } else { byte }
    } nobreak {
      byte.to_byte()
    }
  })
}

///|
/// Appends the `n` bits of `value`, lowest first.
fn push_bits(bits : Array[Bool], n : Int32, value : Int32) -> Unit {
  for i in 0..<n {
    bits.push(((value >> i) & 1) == 1)
  }
}

///|
/// Everything `w` holds for the caller, handed out `room` bytes at a time,
/// alternately through `drain` and `drain_into`.
fn take(w : @bits.BitPacker, room : Int32) -> Bytes {
  let out = Buffer()
  let chunk = FixedArray::make(room, b'\x00')
  for i = 0; w.pending() > 0; i = i + 1 {
    let n = if i % 2 == 0 {
      w.drain(chunk.mut_view(), 0)
    } else {
      w.drain_into(chunk, 0)
    }
    out.write_bytesview(Bytes::from_array(chunk[:n])[:])
  }
  out.to_bytes()
}

///|
test "bits are packed least significant first" {
  let w = @bits.BitPacker()
  w.write(3, 0b101)
  w.write(5, 0b11001)
  w.write(4, 0b0110)
  inspect(w.position(), content="12")
  inspect(w.pending(), content="1")
  inspect(w.is_aligned(), content="false")
  w.align()
  inspect(w.is_aligned(), content="true")
  // 101 then 11001 is 0b11001_101; 0110 then four zero bits.
  debug_inspect(
    take(w, 16),
    content=(
      #|<Bytes: [0xcd, 0x06]>
    ),
  )
  inspect(w.position(), content="0")
}

///|
test "random writes of up to 32 bits match the packing bit by bit" {
  let rng = { state: 1951, }
  for round in 0..<50 {
    let w = @bits.BitPacker()
    let bits = []
    let out = Buffer()
    for _ in 0..<(1 + rng.below(400)) {
      let n = rng.below(33)
      let v = rng.bits(n)
      w.write(n, v)
      push_bits(bits, n, v)
      // Bytes now and then: they follow the bits so far, aligned.
      if rng.below(20) == 0 {
        w.align()
        while bits.length() % 8 != 0 {
          bits.push(false)
        }
        let data = FixedArray::makei(rng.below(10), _ => {
          rng.below(256).to_byte()
        })
        w.write_bytes(data, 0, data.length())
        for b in data {
          push_bits(bits, 8, b.to_int())
        }
      }
      // Hand out what is complete now and then.
      if rng.below(10) == 0 {
        out.write_bytes(take(w, 1 + rng.below(7)))
      }
    }
    w.align()
    out.write_bytes(take(w, 1 + round))
    assert_eq(out.to_bytes(), pack(bits))
  }
}

///|
test "rewind drops what was written since the mark" {
  let rng = { state: 7, }
  for _ in 0..<200 {
    let w = @bits.BitPacker()
    let bits = []
    for _ in 0..<rng.below(40) {
      let n = rng.below(33)
      let v = rng.bits(n)
      w.write(n, v)
      push_bits(bits, n, v)
    }
    let mark = w.mark()
    let at = w.position()
    for _ in 0..<rng.below(40) {
      w.write(rng.below(33), 0)
    }
    w.rewind(mark)
    assert_eq(w.position(), at)
    let n = rng.below(33)
    let v = rng.bits(n)
    w.write(n, v)
    push_bits(bits, n, v)
    w.align()
    assert_eq(take(w, 64), pack(bits))
  }
}

///|
test "the buffer empties once handed out, and reset forgets everything" {
  let w = @bits.BitPacker()
  for _ in 0..<10 {
    w.write(32, -1)
  }
  w.write(3, 5)
  inspect(w.pending(), content="40")
  inspect(w.buffered(), content="40")
  let out = FixedArray::make(30, b'\x00')
  inspect(w.drain_into(out, 5), content="30")
  inspect(w.pending(), content="15")
  inspect(w.buffered(), content="40")
  // A full output takes nothing.
  inspect(w.drain(out.mut_view(), 30), content="30")
  inspect(w.drain(out.mut_view(), 15), content="30")
  // All handed out: the buffer is empty, the partial byte stays.
  inspect(w.buffered(), content="0")
  inspect(w.position(), content="3")
  let capacity = w.capacity()
  assert_true(capacity >= 40)
  w.reset()
  inspect(w.position(), content="0")
  inspect(w.is_aligned(), content="true")
  inspect(w.capacity() == capacity, content="true")
  w.write(8, 0xa5)
  debug_inspect(
    take(w, 4),
    content=(
      #|<Bytes: [0xa5]>
    ),
  )
}

///|
test "the end mark is the highest set bit of the last byte" {
  let rng = { state: 8878, }
  for n in 0..<200 {
    let w = @bits.BitPacker()
    let bits = []
    for _ in 0..<n {
      let v = rng.below(2)
      w.write(1, v)
      push_bits(bits, 1, v)
    }
    w.write_end_mark()
    inspect(w.is_aligned(), content="true")
    let out = take(w, 64)
    assert_eq(out.length(), n / 8 + 1)
    // Reading back from the last byte: the mark, then the bits written.
    let last = out[out.length() - 1].to_int()
    let mark = 31 - last.clz()
    assert_eq((out.length() - 1) * 8 + mark, n)
    for i in 0..<n {
      let set = ((out[i / 8].to_int() >> (i % 8)) & 1) == 1
      assert_eq(set, bits[i])
    }
  }
}

///|
test "write_pending moves the waiting bytes of another writer" {
  let w = @bits.BitPacker()
  let other = @bits.BitPacker()
  w.write(8, 0x11)
  for i in 0..<6 {
    other.write(8, i)
  }
  other.write(3, 5)
  // Part of the other's bytes already handed out: only the rest moves.
  let out = FixedArray::make(2, b'\x00')
  inspect(other.drain_into(out, 0), content="2")
  w.write_pending(other)
  inspect(other.pending(), content="0")
  inspect(other.buffered(), content="0")
  inspect(other.position(), content="3")
  debug_inspect(
    take(w, 16),
    content=(
      #|<Bytes: [0x11, 0x02, 0x03, 0x04, 0x05]>
    ),
  )
}

///|
test "whole bytes waiting count as pending and keep the writer aligned" {
  let w = @bits.BitPacker()
  w.write(8, 0x5a)
  inspect(w.is_aligned(), content="true")
  inspect(w.position(), content="8")
  inspect(w.pending(), content="1")
  w.write(12, 0xabc)
  inspect(w.is_aligned(), content="false")
  inspect(w.buffered(), content="2")
  w.align()
  inspect(w.position(), content="24")
  debug_inspect(
    take(w, 2),
    content=(
      #|<Bytes: [0x5a, 0xbc, 0x0a]>
    ),
  )
}

///|
test "writes across every byte boundary near the end of the buffer" {
  // A writer whose buffer holds exactly `size` bytes, after reset: the
  // writes reach its end at every offset, through every write width, so
  // whole bytes are moved both with room for eight and without.
  for size in [1, 2, 7, 8, 9, 15, 16, 17, 64] {
    for lead in 0..<72 {
      for n in [1, 7, 8, 9, 15, 16, 17, 24, 31, 32] {
        let w = @bits.BitPacker()
        w.write_bytes(FixedArray::make(size, b'\x00'), 0, size)
        assert_eq(w.capacity(), size)
        w.reset()
        let bits = []
        push_bits(bits, lead % 8, 0b1010101)
        w.write(lead % 8, 0b1010101 & ((1 << (lead % 8)) - 1))
        for k in 0..<(lead / 8) {
          w.write(8, k * 37 % 256)
          push_bits(bits, 8, k * 37 % 256)
        }
        for k in 0..<12 {
          let v = if n == 32 { -1 - k } else { ((1 << n) - 1) ^ k }
          let v = if n == 32 { v } else { v & ((1 << n) - 1) }
          w.write(n, v)
          push_bits(bits, n, v)
        }
        w.align()
        assert_eq(take(w, 64), pack(bits))
      }
    }
  }
}

///|
test "rewind after whole bytes reached the buffer" {
  let rng = { state: 4141, }
  for _ in 0..<300 {
    let w = @bits.BitPacker()
    let bits = []
    for _ in 0..<rng.below(12) {
      let n = rng.below(33)
      let v = rng.bits(n)
      w.write(n, v)
      push_bits(bits, n, v)
    }
    let mark = w.mark()
    // Long writes after the mark move bytes into the buffer, and past it.
    for _ in 0..<(1 + rng.below(10)) {
      w.write(32, -1)
      w.write(rng.below(33), 0)
    }
    w.rewind(mark)
    for _ in 0..<rng.below(12) {
      let n = rng.below(33)
      let v = rng.bits(n)
      w.write(n, v)
      push_bits(bits, n, v)
    }
    w.align()
    assert_eq(take(w, 64), pack(bits))
  }
}

///|
test "partial drains between writes hand out the bits in order" {
  let rng = { state: 2024, }
  for _ in 0..<100 {
    let w = @bits.BitPacker()
    let bits = []
    let out = Buffer()
    let chunk = FixedArray::make(8, b'\x00')
    for _ in 0..<(1 + rng.below(300)) {
      let n = rng.below(33)
      let v = rng.bits(n)
      w.write(n, v)
      push_bits(bits, n, v)
      if rng.below(4) == 0 {
        // Fewer bytes than are waiting, sometimes: the rest stays.
        let room = rng.below(9)
        let before = w.pending()
        let got = if rng.below(2) == 0 {
          w.drain(chunk.mut_view(), 8 - room)
        } else {
          w.drain_into(chunk, 8 - room)
        }
        let taken = got - (8 - room)
        assert_eq(taken, before.min(room))
        assert_eq(w.pending(), before - taken)
        out.write_bytesview(Bytes::from_array(chunk[8 - room:got])[:])
      }
    }
    w.write_end_mark()
    out.write_bytes(take(w, 3))
    bits.push(true)
    while bits.length() % 8 != 0 {
      bits.push(false)
    }
    assert_eq(out.to_bytes(), pack(bits))
  }
}
