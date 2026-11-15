///|
/// The largest hash table, 2^14 entries, as snappy's `kMaxHashTableSize`.
const MAX_HASH_BITS : Int32 = 14

///|
/// Bytes at a fragment's end the match search leaves alone, so that its
/// four- and eight-byte reads stay within the fragment (`kInputMarginBytes`).
const INPUT_MARGIN : Int32 = 15

///|
/// An output array with room for all the encoder writes into it.
priv struct Writer {
  data : FixedArray[Byte]
  mut pos : Int32
}

///|
fn Writer::new(capacity : Int32) -> Writer {
  { data: FixedArray::make(capacity.max(1), b'\x00'), pos: 0, }
}

///|
fn Writer::byte(self : Writer, b : Int32) -> Unit {
  self.data[self.pos] = b.to_byte()
  self.pos += 1
}

///|
fn Writer::varint(self : Writer, n : Int32) -> Unit {
  let mut v = n.reinterpret_as_uint()
  while v >= 0x80 {
    self.byte((v & 0x7F).reinterpret_as_int() | 0x80)
    v = v >> 7
  }
  self.byte(v.reinterpret_as_int())
}

///|
fn Writer::to_bytes(self : Writer) -> Bytes {
  Bytes::from_array(self.data[0:self.pos])
}

///|
/// The four bytes at `i`, little-endian; the caller has checked that they are
/// within `data`.
fn load32(data : BytesView, i : Int32) -> UInt32 {
  data[i].to_uint() |
  (data[i + 1].to_uint() << 8) |
  (data[i + 2].to_uint() << 16) |
  (data[i + 3].to_uint() << 24)
}

///|
/// snappy's hash of four bytes into `32 - shift` bits.
fn hash(bytes : UInt32, shift : Int32) -> Int32 {
  ((bytes * 0x1E35A7BD) >> shift).reinterpret_as_int()
}

///|
/// A literal of `data[from:to]`, `to > from`: its tag, with the length
/// minus one in it below 60 and in 1 to 4 bytes after it otherwise.
fn emit_literal(
  out : Writer,
  data : BytesView,
  from : Int32,
  to : Int32,
) -> Unit {
  let n = to - from - 1
  if n < 60 {
    out.byte(n << 2)
  } else {
    let at = out.pos
    out.pos += 1
    let mut v = n
    let mut count = 0
    while v > 0 {
      out.byte(v & 0xFF)
      v = v >> 8
      count += 1
    }
    out.data[at] = ((59 + count) << 2).to_byte()
  }
  out.data.blit_from_bytesview(out.pos, data[from:to])
  out.pos += to - from
}

///|
/// A copy of 1 to 64 bytes, `offset` back (below 65,536): with a one-byte
/// offset when it is shorter than 12 and the offset below 2,048.
fn emit_copy_at_most_64(out : Writer, offset : Int32, len : Int32) -> Unit {
  if len < 12 && offset < 2048 {
    out.byte(1 | ((len - 4) << 2) | (offset >> 8 << 5))
    out.byte(offset & 0xFF)
  } else {
    out.byte(2 | ((len - 1) << 2))
    out.byte(offset & 0xFF)
    out.byte(offset >> 8)
  }
}

///|
/// A copy of `len` bytes (4 or more), `offset` back, as copies of at most
/// 64: 64 at a time while 68 or more are left, so that the last copy has at
/// least 4, as snappy's `EmitCopy` does.
fn emit_copy(out : Writer, offset : Int32, len : Int32) -> Unit {
  let mut left = len
  while left >= 68 {
    emit_copy_at_most_64(out, offset, 64)
    left -= 64
  }
  if left > 64 {
    emit_copy_at_most_64(out, offset, 60)
    left -= 60
  }
  emit_copy_at_most_64(out, offset, left)
}

///|
/// Compresses `data[start:end]`, at most 64 KiB, on its own: matches reach
/// no further back than `start`. `table` holds positions from `start`.
fn compress_fragment(
  data : BytesView,
  start : Int32,
  end : Int32,
  out : Writer,
  table : FixedArray[UInt16],
) -> Unit {
  let size = end - start
  let mut bits = 8
  while bits < MAX_HASH_BITS && 1 << bits < size {
    bits += 1
  }
  let shift = 32 - bits
  table.fill(0, end=1 << bits)
  let mut next_emit = start
  if size >= INPUT_MARGIN {
    let ip_limit = end - INPUT_MARGIN
    let mut ip = start + 1
    let mut next_hash = hash(load32(data, ip), shift)
    // From here on, a position has four bytes after it within the fragment:
    // ip <= ip_limit.
    let mut done = false
    while !done {
      let mut skip = 32
      let mut next_ip = ip
      let mut candidate = 0
      for ;; {
        ip = next_ip
        let h = next_hash
        let step = skip >> 5
        skip += step
        next_ip = ip + step
        if next_ip > ip_limit {
          done = true
          break
        }
        next_hash = hash(load32(data, next_ip), shift)
        candidate = start + table[h].to_int()
        table[h] = (ip - start).to_uint16()
        if load32(data, ip) == load32(data, candidate) {
          break
        }
      }
      if done {
        break
      }
      emit_literal(out, data, next_emit, ip)
      for ;; {
        let base = ip
        let mut matched = 4
        while ip + matched < end &&
              data[candidate + matched] == data[ip + matched] {
          matched += 1
        }
        ip += matched
        emit_copy(out, base - candidate, matched)
        next_emit = ip
        if ip >= ip_limit {
          done = true
          break
        }
        table[hash(load32(data, ip - 1), shift)] = (ip - 1 - start).to_uint16()
        let h = hash(load32(data, ip), shift)
        candidate = start + table[h].to_int()
        table[h] = (ip - start).to_uint16()
        if load32(data, ip) != load32(data, candidate) {
          break
        }
      }
      if done {
        break
      }
      ip += 1
      next_hash = hash(load32(data, ip), shift)
    }
  }
  if next_emit < end {
    emit_literal(out, data, next_emit, end)
  }
}
