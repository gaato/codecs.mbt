// A hash-chain match finder, ported from libdeflate's hc_matchfinder.h
// (1.24): one table that keeps the latest position of each 3-byte hash, for
// matches of length 3, and chains through the 32 KiB window for each 4-byte
// hash, for longer ones. It finds what libdeflate's finds, byte for byte.
//
// Positions are inserted in order, one call per position: `longest_match`
// inserts the position it searches, `skip_bytes` those it passes over. Each
// call also hashes the next position, so the finder keeps the hashes of
// `next_pos`, the first position not inserted yet. Near the end of the
// bytes the caller has (fewer than `REQUIRED_BYTES` left), positions cannot
// be inserted; `catch_up` inserts them once more bytes have come.

///|
const HASH3_BITS : Int32 = 15

///|
const HASH4_BITS : Int32 = 16

///|
/// A hash-chain match finder over a buffer of the caller's.
pub struct HcMatchfinder {
  // The latest position of each 3-byte hash and of each 4-byte hash, and for
  // each position of the window the one before it with its 4-byte hash.
  priv hash3 : FixedArray[Int16]
  priv hash4 : FixedArray[Int16]
  priv next : FixedArray[Int16]
  // The buffer index that stored positions count from.
  priv mut base : Int32
  // The hashes of `next_pos`.
  priv mut next_hash3 : Int32
  priv mut next_hash4 : Int32
  priv mut next_pos : Int32
  // How far back the latest match found is.
  priv mut offset : Int32
}

///|
/// A finder with its tables allocated; `reset` starts it.
pub fn HcMatchfinder::HcMatchfinder() -> HcMatchfinder {
  {
    hash3: FixedArray::make(1 << HASH3_BITS, NO_POSITION),
    hash4: FixedArray::make(1 << HASH4_BITS, NO_POSITION),
    next: FixedArray::make(WINDOW, NO_POSITION),
    base: 0,
    next_hash3: 0,
    next_hash4: 0,
    next_pos: 0,
    offset: 0,
  }
}

///|
/// Forgets every position: the next one to insert is `start`. Its hashes
/// are taken as 0, as libdeflate does, until a call computes them (see
/// `catch_up`).
pub fn HcMatchfinder::reset(self : HcMatchfinder, start : Int32) -> Unit {
  self.hash3.fill(NO_POSITION)
  self.hash4.fill(NO_POSITION)
  self.next.fill(NO_POSITION)
  self.base = start
  self.next_hash3 = 0
  self.next_hash4 = 0
  self.next_pos = start
  self.offset = 0
}

///|
/// The tables' bytes: 262,144.
pub fn HcMatchfinder::memory_usage(self : HcMatchfinder) -> Int32 {
  2 * (self.hash3.length() + self.hash4.length() + self.next.length())
}

///|
/// The caller moved its bytes `delta` places down in its buffer.
pub fn HcMatchfinder::move_down(self : HcMatchfinder, delta : Int32) -> Unit {
  self.base -= delta
  self.next_pos -= delta
}

///|
/// How far back the match `longest_match` found last is (0 for none).
pub fn HcMatchfinder::offset(self : HcMatchfinder) -> Int32 {
  self.offset
}

///|
/// The first position not inserted yet.
pub fn HcMatchfinder::next_pos(self : HcMatchfinder) -> Int32 {
  self.next_pos
}

///|
/// Moves the base 32 KiB up when the position `cur_pos` from it has left
/// the stored range; the position from the new base.
#inline
fn HcMatchfinder::slide_if_needed(
  self : HcMatchfinder,
  cur_pos : Int32,
) -> Int32 {
  if cur_pos >= WINDOW {
    rebase(self.hash3)
    rebase(self.hash4)
    rebase(self.next)
    self.base += WINDOW
    cur_pos - WINDOW
  } else {
    cur_pos
  }
}

///|
/// Inserts `in_next`, which must be `next_pos`, and returns the length of
/// the longest match there longer than `best_len`, at most `max_len`, with
/// its offset in `offset()` (0 if none is longer, and then `best_len` is
/// returned). The search stops at a match of `nice_len` or after
/// `max_search_depth` 4-byte candidates. With `max_len` below
/// `REQUIRED_BYTES` it neither inserts nor searches. The bytes up to
/// `in_next + max_len` must be in `data`, and `in_next + 4` too when
/// `max_len` allows a search.
pub fn HcMatchfinder::longest_match(
  self : HcMatchfinder,
  data : FixedArray[Byte],
  in_next : Int32,
  best_len : Int32,
  max_len : Int32,
  nice_len : Int32,
  max_search_depth : Int32,
) -> Int32 {
  if max_len < REQUIRED_BYTES {
    self.offset = 0
    return best_len
  }
  // libdeflate slides before the test above; sliding only when a position
  // goes in keeps `next_pos` at or after the base.
  let cur_pos = self.slide_if_needed(in_next - self.base)
  let base = self.base
  let cutoff = cur_pos - WINDOW
  let next_tab = self.next
  let mut best_len = best_len
  let mut best_match = in_next
  let mut depth_remaining = max_search_depth
  // Insert this position, and hash the next one.
  let cur_node3 = self.hash3[self.next_hash3].to_int()
  let mut cur_node4 = self.hash4[self.next_hash4].to_int()
  self.hash3[self.next_hash3] = Int16::from_int(cur_pos)
  self.hash4[self.next_hash4] = Int16::from_int(cur_pos)
  next_tab[cur_pos] = Int16::from_int(cur_node4)
  let next_seq = load_u32(data, in_next + 1)
  self.next_hash3 = hash_bits(next_seq & 0xFFFFFF, HASH3_BITS)
  self.next_hash4 = hash_bits(next_seq, HASH4_BITS)
  self.next_pos = in_next + 1
  // Each `return` below is one of libdeflate's `goto out`.
  if best_len < 4 {
    if cur_node3 <= cutoff {
      self.offset = 0
      return best_len
    }
    let seq4 = load_u32(data, in_next)
    if best_len < 3 {
      let m = base + cur_node3
      if (load_u32(data, m) & 0xFFFFFF) == (seq4 & 0xFFFFFF) {
        best_len = 3
        best_match = m
      }
    }
    if cur_node4 <= cutoff {
      self.offset = in_next - best_match
      return best_len
    }
    // The first 4-byte candidate whose bytes match.
    while load_u32(data, base + cur_node4) != seq4 {
      cur_node4 = next_tab[cur_node4 & (WINDOW - 1)].to_int()
      depth_remaining -= 1
      if cur_node4 <= cutoff || depth_remaining == 0 {
        self.offset = in_next - best_match
        return best_len
      }
    }
    best_match = base + cur_node4
    best_len = extend_match(data, in_next, best_match, 4, max_len)
    if best_len >= nice_len {
      self.offset = in_next - best_match
      return best_len
    }
    cur_node4 = next_tab[cur_node4 & (WINDOW - 1)].to_int()
    depth_remaining -= 1
    if cur_node4 <= cutoff || depth_remaining == 0 {
      self.offset = in_next - best_match
      return best_len
    }
  } else if cur_node4 <= cutoff || best_len >= nice_len {
    self.offset = in_next - best_match
    return best_len
  }
  // Longer matches: a candidate is extended only if it may beat the best.
  // Here best_len < nice_len <= max_len, so the test reads only bytes the
  // match may cover.
  while true {
    let m = base + cur_node4
    if may_beat(data, m, in_next, best_len) {
      let len = extend_match(data, in_next, m, 1, max_len)
      if len > best_len {
        best_len = len
        best_match = m
        if best_len >= nice_len {
          break
        }
      }
    }
    cur_node4 = next_tab[cur_node4 & (WINDOW - 1)].to_int()
    depth_remaining -= 1
    if cur_node4 <= cutoff || depth_remaining == 0 {
      break
    }
  }
  self.offset = in_next - best_match
  best_len
}

///|
/// Inserts the `count` positions from `in_next`, which must be `next_pos`,
/// without searching. When fewer than `count + REQUIRED_BYTES` bytes are
/// left before `in_end`, it inserts none of them, as libdeflate does; then
/// `next_pos` stays at `in_next`.
pub fn HcMatchfinder::skip_bytes(
  self : HcMatchfinder,
  data : FixedArray[Byte],
  in_next : Int32,
  in_end : Int32,
  count : Int32,
) -> Unit {
  if count + REQUIRED_BYTES > in_end - in_next {
    return
  }
  let hash3_tab = self.hash3
  let hash4_tab = self.hash4
  let next_tab = self.next
  let mut cur_pos = self.slide_if_needed(in_next - self.base)
  let mut hash3 = self.next_hash3
  let mut hash4 = self.next_hash4
  let mut pos = in_next
  for _ in 0..<count {
    if cur_pos == WINDOW {
      cur_pos = self.slide_if_needed(cur_pos)
    }
    hash3_tab[hash3] = Int16::from_int(cur_pos)
    next_tab[cur_pos] = hash4_tab[hash4]
    hash4_tab[hash4] = Int16::from_int(cur_pos)
    pos += 1
    let seq = load_u32(data, pos)
    hash3 = hash_bits(seq & 0xFFFFFF, HASH3_BITS)
    hash4 = hash_bits(seq, HASH4_BITS)
    cur_pos += 1
  }
  self.next_hash3 = hash3
  self.next_hash4 = hash4
  self.next_pos = pos
}

///|
/// Inserts the positions from `next_pos` up to `in_next`, hashing them
/// afresh, as far as the bytes before `in_end` allow: positions left out
/// near the end of the bytes a caller had, once it has more. Does nothing
/// when every position before `in_next` is in.
pub fn HcMatchfinder::catch_up(
  self : HcMatchfinder,
  data : FixedArray[Byte],
  in_next : Int32,
  in_end : Int32,
) -> Unit {
  let from = self.next_pos
  let to = in_next.min(in_end - REQUIRED_BYTES)
  guard from < to else { return }
  let seq = load_u32(data, from)
  self.next_hash3 = hash_bits(seq & 0xFFFFFF, HASH3_BITS)
  self.next_hash4 = hash_bits(seq, HASH4_BITS)
  self.skip_bytes(data, from, in_end, to - from)
}
