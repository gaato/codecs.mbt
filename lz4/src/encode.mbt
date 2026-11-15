// The block compressor: lz4 1.10.0's LZ4_compress_generic (lib/lz4.c), the
// "fast" one, for its three uses here.
//
// - A block on its own, under 64 KiB + 11 bytes: lz4's byU16 table, 2^13
//   entries hashed from four bytes.
// - A larger block on its own: its byU32 table, 2^12 entries hashed from
//   five bytes, and matches no more than 65,535 bytes back.
// - A block after history (the frame's earlier blocks, or a dictionary): the
//   byU32 table, matches no further back than the history's start.
//
// The first two follow lz4's steps exactly, from a cleared table, so a block
// compressed on its own is the bytes lz4 writes for it (lz4 -BI, and
// LZ4_compress_fast). The third keeps the table across blocks as lz4's
// streaming compressor does, though not its every step.

///|
/// The shortest match.
const MIN_MATCH : Int32 = 4

///|
/// A block's last match starts at least this many bytes before its end.
const MF_LIMIT : Int32 = 12

///|
/// A block's last bytes are always literals.
const LAST_LITERALS : Int32 = 5

///|
/// Blocks shorter than this hold only literals.
const MIN_LENGTH : Int32 = 13

///|
/// The largest block lz4's byU16 table serves (`LZ4_64Klimit`).
const SMALL_LIMIT : Int32 = 65536 + MF_LIMIT - 1

///|
/// The table's entries: 2^13 for the small table, 2^12 for the large one.
const TABLE_ENTRIES : Int32 = 8192

///|
/// The largest input `compress_block` takes, lz4's `LZ4_MAX_INPUT_SIZE`.
const MAX_INPUT : Int32 = 0x7E000000

///|
/// An output array with room for all the compressor writes into it.
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
fn Writer::le32(self : Writer, v : UInt32) -> Unit {
  self.byte((v & 0xFF).reinterpret_as_int())
  self.byte(((v >> 8) & 0xFF).reinterpret_as_int())
  self.byte(((v >> 16) & 0xFF).reinterpret_as_int())
  self.byte((v >> 24).reinterpret_as_int())
}

///|
/// The four bytes at `i`, little-endian; the caller has checked that they
/// are within `data`.
#cfg(any(target="native", target="wasm"))
#inline
fn load32(data : FixedArray[Byte], i : Int32) -> UInt32 {
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint32_le(i)
}

///|
#cfg(not(any(target="native", target="wasm")))
fn load32(data : FixedArray[Byte], i : Int32) -> UInt32 {
  data.unsafe_get(i).to_uint() |
  (data.unsafe_get(i + 1).to_uint() << 8) |
  (data.unsafe_get(i + 2).to_uint() << 16) |
  (data.unsafe_get(i + 3).to_uint() << 24)
}

///|
/// The eight bytes at `i`, little-endian; the caller has checked that they
/// are within `data`.
#cfg(any(target="native", target="wasm"))
#inline
fn load64(data : FixedArray[Byte], i : Int32) -> UInt64 {
  data.unsafe_reinterpret_as_bytes().unsafe_read_uint64_le(i)
}

///|
/// On Wasm GC; JS hashes without it (`hash_large`).
#cfg(target="wasm-gc")
fn load64(data : FixedArray[Byte], i : Int32) -> UInt64 {
  load32(data, i).to_uint64() | (load32(data, i + 4).to_uint64() << 32)
}

///|
/// The small table's hash: `LZ4_hash4` for byU16, of the four bytes at `p`.
#inline
fn hash_small(data : FixedArray[Byte], p : Int32) -> Int32 {
  ((load32(data, p) * 2654435761U) >> 19).reinterpret_as_int()
}

///|
/// The large table's hash: `LZ4_hash5`, of the five bytes at `p` (lz4 reads
/// eight on 64-bit machines and shifts three away).
#cfg(not(target="js"))
#inline
fn hash_large(data : FixedArray[Byte], p : Int32) -> Int32 {
  (((load64(data, p) << 24) * 889523592379UL) >> 52).to_int()
}

///|
/// The same on JS, where a 64-bit integer is a BigInt and every operation
/// on one allocates: the product's high half from 32-bit halves. The five
/// bytes shifted up by 24 are `hi:lo`; 889523592379 is 0xCF:0x1BBCDCBB.
#cfg(target="js")
fn hash_large(data : FixedArray[Byte], p : Int32) -> Int32 {
  let x = load32(data, p)
  let lo = x << 24
  let hi = (x >> 8) | (data.unsafe_get(p + 4).to_uint() << 24)
  let top = hi * 0x1BBCDCBBU + lo * 0xCFU + mul_high(lo, 0x1BBCDCBBU)
  (top >> 20).reinterpret_as_int()
}

///|
/// The high 32 bits of the 64-bit product of `a` and `b`, from 16-bit
/// halves whose products fit in 32 bits.
#cfg(target="js")
fn mul_high(a : UInt32, b : UInt32) -> UInt32 {
  let a0 = a & 0xFFFF
  let a1 = a >> 16
  let b0 = b & 0xFFFF
  let b1 = b >> 16
  let p00 = a0 * b0
  let p01 = a0 * b1
  let p10 = a1 * b0
  let mid = (p00 >> 16) + (p01 & 0xFFFF) + (p10 & 0xFFFF)
  a1 * b1 + (p01 >> 16) + (p10 >> 16) + (mid >> 16)
}

///|
#inline
fn hash_at(data : FixedArray[Byte], p : Int32, small : Bool) -> Int32 {
  if small {
    hash_small(data, p)
  } else {
    hash_large(data, p)
  }
}

///|
/// How many bytes from `a` equal those from `b`, `a > b`, stopping at
/// `limit`: lz4's `LZ4_count`.
#cfg(any(target="native", target="wasm"))
fn count_match(
  data : FixedArray[Byte],
  a : Int32,
  b : Int32,
  limit : Int32,
) -> Int32 {
  let start = a
  let mut a = a
  let mut b = b
  while a + 8 <= limit {
    let diff = load64(data, a) ^ load64(data, b)
    if diff != 0 {
      return a - start + diff.ctz() / 8
    }
    a += 8
    b += 8
  }
  while a < limit && data.unsafe_get(a) == data.unsafe_get(b) {
    a += 1
    b += 1
  }
  a - start
}

///|
#cfg(not(any(target="native", target="wasm")))
fn count_match(
  data : FixedArray[Byte],
  a : Int32,
  b : Int32,
  limit : Int32,
) -> Int32 {
  let start = a
  let mut a = a
  let mut b = b
  while a + 4 <= limit {
    let diff = load32(data, a) ^ load32(data, b)
    if diff != 0 {
      return a - start + diff.ctz() / 8
    }
    a += 4
    b += 4
  }
  while a < limit && data.unsafe_get(a) == data.unsafe_get(b) {
    a += 1
    b += 1
  }
  a - start
}

///|
/// How a block is compressed: which table, and whether candidates before
/// `low` (stale ones, from history no longer there) are refused.
priv struct Mode {
  small : Bool
  check_low : Bool
  acceleration : Int32
}

///|
/// Compresses `src[start:end]` into `out`, as lz4 does; matches reach back
/// no further than `low` (and 65,535 bytes). `table` holds positions in
/// `src`. Gives false when the output would pass `olimit`, as lz4's
/// limitedOutput does, with `out` then partly written.
fn compress_into(
  src : FixedArray[Byte],
  start : Int32,
  end : Int32,
  low : Int32,
  table : FixedArray[Int32],
  mode : Mode,
  out : Writer,
  olimit : Int32,
) -> Bool {
  let anchor = sequences(src, start, end, low, table, mode, out, olimit)
  guard anchor >= 0 else { return false }
  // The last literals.
  let last = end - anchor
  if out.pos + last + 1 + (last + 255 - 15) / 255 > olimit {
    return false
  }
  if last >= 15 {
    out.byte(0xF0)
    let mut rest = last - 15
    while rest >= 255 {
      out.byte(255)
      rest -= 255
    }
    out.byte(rest)
  } else {
    out.byte(last << 4)
  }
  FixedArray::unsafe_blit(out.data, out.pos, src, anchor, last)
  out.pos += last
  true
}

///|
/// The sequences before the last literals: where those start, or -1 when
/// the output would pass `olimit`.
fn sequences(
  src : FixedArray[Byte],
  start : Int32,
  end : Int32,
  low : Int32,
  table : FixedArray[Int32],
  mode : Mode,
  out : Writer,
  olimit : Int32,
) -> Int32 {
  let small = mode.small
  let check_low = mode.check_low
  let mut anchor = start
  if end - start < MIN_LENGTH {
    return anchor
  }
  let dst = out.data
  let mut op = out.pos
  let mflimit_plus_one = end - MF_LIMIT + 1
  let match_limit = end - LAST_LITERALS
  table[hash_at(src, start, small)] = start
  let mut ip = start + 1
  let mut forward_h = hash_at(src, ip, small)
  for ;; {
    // Find a match, stepping faster the longer none is found.
    let mut forward_ip = ip
    let mut step = 1
    let mut search = mode.acceleration << 6
    let mut m = 0
    for ;; {
      let h = forward_h
      let current = forward_ip
      let candidate = table[h]
      ip = forward_ip
      forward_ip += step
      step = search >> 6
      search += 1
      if forward_ip > mflimit_plus_one {
        out.pos = op
        return anchor
      }
      forward_h = hash_at(src, forward_ip, small)
      table[h] = current
      if check_low && candidate < low {
        continue
      }
      if !small && candidate + MAX_DISTANCE < current {
        continue
      }
      if load32(src, candidate) == load32(src, ip) {
        m = candidate
        break
      }
    }
    // Catch up: the match may begin earlier.
    while ip > anchor && m > low && src[ip - 1] == src[m - 1] {
      ip -= 1
      m -= 1
    }
    // The literals.
    let lit = ip - anchor
    let mut token = op
    op += 1
    if op + lit + (2 + 1 + LAST_LITERALS) + lit / 255 > olimit {
      return -1
    }
    if lit >= 15 {
      dst[token] = b'\xF0'
      let mut rest = lit - 15
      while rest >= 255 {
        dst[op] = b'\xFF'
        op += 1
        rest -= 255
      }
      dst[op] = rest.to_byte()
      op += 1
    } else {
      dst[token] = (lit << 4).to_byte()
    }
    FixedArray::unsafe_blit(dst, op, src, anchor, lit)
    op += lit
    // The match, and those that follow it straight away.
    for ;; {
      let offset = ip - m
      dst[op] = (offset & 0xFF).to_byte()
      dst[op + 1] = (offset >> 8).to_byte()
      op += 2
      let code = count_match(src, ip + MIN_MATCH, m + MIN_MATCH, match_limit)
      ip += code + MIN_MATCH
      if op + (1 + LAST_LITERALS) + (code + 240) / 255 > olimit {
        return -1
      }
      if code >= 15 {
        dst[token] = (dst[token].to_int() + 15).to_byte()
        let mut rest = code - 15
        while rest >= 255 {
          dst[op] = b'\xFF'
          op += 1
          rest -= 255
        }
        dst[op] = rest.to_byte()
        op += 1
      } else {
        dst[token] = (dst[token].to_int() + code).to_byte()
      }
      anchor = ip
      if ip >= mflimit_plus_one {
        out.pos = op
        return anchor
      }
      table[hash_at(src, ip - 2, small)] = ip - 2
      // Test the next position.
      let h = hash_at(src, ip, small)
      let candidate = table[h]
      table[h] = ip
      if (!check_low || candidate >= low) &&
        (small || candidate + MAX_DISTANCE >= ip) &&
        load32(src, candidate) == load32(src, ip) {
        token = op
        dst[op] = b'\x00'
        op += 1
        m = candidate
        continue
      }
      break
    }
    ip += 1
    forward_h = hash_at(src, ip, small)
  }
}

///|
/// Hashes every position of `src[low:end]` with eight bytes after it into
/// the large table, as history the next block may match.
fn load_history(
  src : FixedArray[Byte],
  low : Int32,
  end : Int32,
  table : FixedArray[Int32],
) -> Unit {
  let mut p = low
  while p + 8 <= end {
    table[hash_large(src, p)] = p
    p += 1
  }
}

///|
/// The most bytes `compress_block` writes for `n` bytes of input: lz4's
/// `LZ4_COMPRESSBOUND`, `n + n / 255 + 16`. A negative `n` counts as 0; past
/// 2^62 the result is the largest Int64.
pub fn block_compress_bound(n : Int64) -> Int64 {
  let n = n.max(0L)
  guard n <= 0x3FFFFFFFFFFFFFFFL else { return 0x7FFFFFFFFFFFFFFFL }
  n + n / 255L + 16L
}

///|
/// Compresses `input` into one LZ4 block, with nothing around it: the
/// caller keeps its length and the size it decodes to, which
/// `decompress_block` needs a bound of. Without a dictionary these are the
/// bytes lz4's `LZ4_compress_fast` writes, at the same `acceleration` (1, the
/// default, compresses most; higher is faster; values below 1 count as 1).
/// With `dictionary`, matches may reach into its last 64 KiB, as with
/// `LZ4_compress_fast_continue` after `LZ4_loadDict`; the decoder needs the
/// same dictionary. Inputs over 2,113,929,216 bytes, lz4's
/// `LZ4_MAX_INPUT_SIZE`, abort.
pub fn compress_block(
  input : BytesView,
  acceleration~ : Int32 = 1,
  dictionary? : BytesView,
) -> Bytes {
  let n = input.length()
  guard n <= MAX_INPUT else {
    abort("compress_block: \{n} bytes, over lz4's 2,113,929,216")
  }
  let acceleration = acceleration.max(1).min(65537)
  let out = Writer::new(block_compress_bound(n.to_int64()).to_int())
  let table = FixedArray::make(TABLE_ENTRIES, 0)
  match dictionary {
    Some(d) if d.length() > 0 => {
      let d = d[(d.length() - MAX_DISTANCE).max(0):]
      let src = FixedArray::make(d.length() + n, b'\x00')
      src.blit_from_bytesview(0, d)
      src.blit_from_bytesview(d.length(), input)
      table.fill(-1)
      load_history(src, 0, d.length(), table)
      let mode = { small: false, check_low: true, acceleration, }
      let _ = compress_into(
        src,
        d.length(),
        src.length(),
        0,
        table,
        mode,
        out,
        out.data.length(),
      )
    }
    _ => {
      let src = FixedArray::make(n, b'\x00')
      src.blit_from_bytesview(0, input)
      let mode = { small: n < SMALL_LIMIT, check_low: false, acceleration, }
      let _ = compress_into(src, 0, n, 0, table, mode, out, out.data.length())
    }
  }
  Bytes::from_array(out.data[0:out.pos])
}
