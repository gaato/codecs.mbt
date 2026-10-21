// A hash-table match finder, ported from libdeflate's ht_matchfinder.h
// (1.24): each 4-byte hash keeps its two latest positions, and only those are
// tried. Faster than `HcMatchfinder`, and finds less; it finds what
// libdeflate's finds, byte for byte.
//
// Positions are inserted in order, as for `HcMatchfinder`: `longest_match`
// inserts the position it searches, `skip_bytes` those it passes over, and
// `catch_up` those that had to wait for more bytes.

///|
const HT_HASH_BITS : Int32 = 15

///|
/// A hash-table match finder over a buffer of the caller's.
pub struct HtMatchfinder {
  // Two entries for each hash: the latest position and the one before.
  priv table : FixedArray[Int16]
  // The buffer index that stored positions count from.
  priv mut base : Int32
  // The hash of `next_pos`.
  priv mut next_hash : Int32
  priv mut next_pos : Int32
  // How far back the latest match found is.
  priv mut offset : Int32
}

///|
/// A finder with its table allocated; `reset` starts it.
pub fn HtMatchfinder::HtMatchfinder() -> HtMatchfinder {
  {
    table: FixedArray::make(2 << HT_HASH_BITS, NO_POSITION),
    base: 0,
    next_hash: 0,
    next_pos: 0,
    offset: 0,
  }
}

///|
/// Forgets every position: the next one to insert is `start`, its hash
/// taken as 0, as libdeflate does, until a call computes it.
pub fn HtMatchfinder::reset(self : HtMatchfinder, start : Int32) -> Unit {
  self.table.fill(NO_POSITION)
  self.base = start
  self.next_hash = 0
  self.next_pos = start
  self.offset = 0
}

///|
/// The table's bytes: 131,072.
pub fn HtMatchfinder::memory_usage(self : HtMatchfinder) -> Int32 {
  2 * self.table.length()
}

///|
/// The caller moved its bytes `delta` places down in its buffer.
pub fn HtMatchfinder::move_down(self : HtMatchfinder, delta : Int32) -> Unit {
  self.base -= delta
  self.next_pos -= delta
}

///|
/// How far back the match `longest_match` found last is (0 for none).
pub fn HtMatchfinder::offset(self : HtMatchfinder) -> Int32 {
  self.offset
}

///|
/// The first position not inserted yet.
pub fn HtMatchfinder::next_pos(self : HtMatchfinder) -> Int32 {
  self.next_pos
}

///|
/// Inserts `in_next`, which must be `next_pos`, and returns the length of
/// the longest match there of at least 4 bytes, at most `max_len`, which
/// must be at least `REQUIRED_BYTES`, or 0; its offset is in `offset()`.
/// The second candidate is tried only while the first is shorter than
/// `nice_len`. The bytes up to `in_next + max_len` must be in `data`.
pub fn HtMatchfinder::longest_match(
  self : HtMatchfinder,
  data : FixedArray[Byte],
  in_next : Int32,
  max_len : Int32,
  nice_len : Int32,
) -> Int32 {
  let mut cur_pos = in_next - self.base
  if cur_pos >= WINDOW {
    rebase(self.table)
    self.base += WINDOW
    cur_pos -= WINDOW
  }
  let base = self.base
  let cutoff = cur_pos - WINDOW
  let table = self.table
  let slot = self.next_hash * 2
  self.next_hash = hash_bits(load_u32(data, in_next + 1), HT_HASH_BITS)
  self.next_pos = in_next + 1
  let seq = load_u32(data, in_next)
  let mut best_len = 0
  let mut best_match = in_next
  let mut cur_node = table[slot].to_int()
  table[slot] = Int16::from_int(cur_pos)
  if cur_node > cutoff {
    let m = base + cur_node
    // The first entry becomes the second, even when the first is nice.
    let to_insert = cur_node
    cur_node = table[slot + 1].to_int()
    table[slot + 1] = Int16::from_int(to_insert)
    if load_u32(data, m) == seq {
      best_len = extend_match(data, in_next, m, 4, max_len)
      best_match = m
      if cur_node > cutoff && best_len < nice_len {
        let m2 = base + cur_node
        if load_u32(data, m2) == seq &&
          load_u32(data, m2 + best_len - 3) ==
          load_u32(data, in_next + best_len - 3) {
          let len = extend_match(data, in_next, m2, 4, max_len)
          if len > best_len {
            best_len = len
            best_match = m2
          }
        }
      }
    } else if cur_node > cutoff {
      let m2 = base + cur_node
      if load_u32(data, m2) == seq {
        best_len = extend_match(data, in_next, m2, 4, max_len)
        best_match = m2
      }
    }
  }
  self.offset = in_next - best_match
  best_len
}

///|
/// Inserts the `count` positions from `in_next`, which must be `next_pos`,
/// without searching; `count` is at most `WINDOW`. When fewer than
/// `count + REQUIRED_BYTES` bytes are left before `in_end`, it inserts none
/// of them, as libdeflate does; then `next_pos` stays at `in_next`.
pub fn HtMatchfinder::skip_bytes(
  self : HtMatchfinder,
  data : FixedArray[Byte],
  in_next : Int32,
  in_end : Int32,
  count : Int32,
) -> Unit {
  if count + REQUIRED_BYTES > in_end - in_next {
    return
  }
  let mut cur_pos = in_next - self.base
  if cur_pos + count - 1 >= WINDOW {
    rebase(self.table)
    self.base += WINDOW
    cur_pos -= WINDOW
  }
  let table = self.table
  let mut hash = self.next_hash
  let mut pos = in_next
  for _ in 0..<count {
    table[hash * 2 + 1] = table[hash * 2]
    table[hash * 2] = Int16::from_int(cur_pos)
    pos += 1
    hash = hash_bits(load_u32(data, pos), HT_HASH_BITS)
    cur_pos += 1
  }
  self.next_hash = hash
  self.next_pos = pos
}

///|
/// Inserts the positions from `next_pos` up to `in_next`, hashing them
/// afresh, as far as the bytes before `in_end` allow, as
/// `HcMatchfinder::catch_up` does. At most `WINDOW` positions wait.
pub fn HtMatchfinder::catch_up(
  self : HtMatchfinder,
  data : FixedArray[Byte],
  in_next : Int32,
  in_end : Int32,
) -> Unit {
  let from = self.next_pos
  let to = in_next.min(in_end - REQUIRED_BYTES)
  guard from < to else { return }
  self.next_hash = hash_bits(load_u32(data, from), HT_HASH_BITS)
  self.skip_bytes(data, from, in_end, to - from)
}
