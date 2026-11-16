// Generated from parts/lz77/bt_matchfinder.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// Port of libdeflate 1.24 lib/bt_matchfinder.h (Eric Biggers, 2016).
//
// Copyright 2016 Eric Biggers
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is furnished to do
// so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

///|
// Fits a 31-bit Smi, so empty slots do not force JS arrays to double elements.
const BT_NO_POSITION : Int32 = -1

///|
/// A binary-tree match finder over the caller's buffer. Positions are absolute
/// Int32 buffer indices, inserted in order, once each, by `get_matches` or
/// `skip_byte`. No buffer movement or position rebasing is implicit.
pub struct BtMatchfinder {
  priv hash3 : FixedArray[Int32]
  priv hash4 : FixedArray[Int32]
  priv children : FixedArray[Int32]
  priv max_distance : Int32
  priv tree_mask : Int32
  priv hash3_bits : Int32
  priv hash4_bits : Int32
  priv mut next_hash3 : Int32
  priv mut next_hash4 : Int32
}

///|
fn bt_tree_size(max_distance : Int32) -> Int32 {
  // Two child indices per slot must fit in Int32. This includes the larger
  // windows used by Brotli and Zstandard, without allocating for them here.
  guard max_distance >= 1 && max_distance <= 1 << 29 else {
    abort("BtMatchfinder: max_distance must be 1 to 2^29")
  }
  for size = 1; size < max_distance; size = size << 1 {

  } nobreak {
    size
  }
}

///|
/// The upper bound in bytes of the finder's fixed array payloads (excluding
/// runtime object headers and the caller's input/output). Same parameters and
/// preconditions as `BtMatchfinder`; pure and does not allocate the arrays.
pub fn bt_memory_bound(
  max_distance~ : Int32 = WINDOW,
  hash3_bits~ : Int32 = 16,
  hash4_bits~ : Int32 = 16,
) -> Int64 {
  guard hash3_bits >= 1 &&
    hash3_bits <= 29 &&
    hash4_bits >= 1 &&
    hash4_bits <= 29 else {
    abort("BtMatchfinder: hash widths must be 1 to 29")
  }
  let tree_size = bt_tree_size(max_distance).to_int64()
  4L * ((2L << hash3_bits) + (1L << hash4_bits) + 2L * tree_size)
}

///|
/// Allocates empty tables. `max_distance` is exclusive, as in libdeflate:
/// matches reach 1 to `max_distance - 1` bytes back. It must be in 1..=2^29;
/// hash widths must be in 1..=29. Tree slots round up to a power of two.
/// Defaults mirror libdeflate 1.24 (two-way hash3, both hashes 16 bits,
/// 32 KiB window). Initial precomputed hashes are zero, as in its compressor.
pub fn BtMatchfinder::BtMatchfinder(
  max_distance~ : Int32 = WINDOW,
  hash3_bits~ : Int32 = 16,
  hash4_bits~ : Int32 = 16,
) -> BtMatchfinder {
  ignore(bt_memory_bound(max_distance~, hash3_bits~, hash4_bits~))
  let tree_size = bt_tree_size(max_distance)
  {
    hash3: FixedArray::make(2 << hash3_bits, BT_NO_POSITION),
    hash4: FixedArray::make(1 << hash4_bits, BT_NO_POSITION),
    children: FixedArray::make(2 * tree_size, BT_NO_POSITION),
    max_distance,
    tree_mask: tree_size - 1,
    hash3_bits,
    hash4_bits,
    next_hash3: 0,
    next_hash4: 0,
  }
}

///|
/// Forgets all positions and restores the initial zero hashes. The first call
/// may start at any nonnegative buffer index; it must then advance sequentially.
pub fn BtMatchfinder::reset(self : BtMatchfinder) -> Unit {
  self.hash3.fill(BT_NO_POSITION)
  self.hash4.fill(BT_NO_POSITION)
  self.children.fill(BT_NO_POSITION)
  self.next_hash3 = 0
  self.next_hash4 = 0
}

///|
/// Counts the tables' element payload, as the other parts' finders do, excluding
/// runtime object headers; on the same basis as `bt_memory_bound`.
pub fn BtMatchfinder::memory_usage(self : BtMatchfinder) -> Int64 {
  4L *
  (
    self.hash3.length().to_int64() +
    self.hash4.length().to_int64() +
    self.children.length().to_int64()
  )
}

///|
/// The caller moved its buffer down by `delta` bytes (which must be >= 0).
/// Subtracts delta from every stored position, clearing those below zero, and
/// rotates the child slots to follow their new indices. Precomputed hashes
/// stay valid for the unchanged bytes at the next position. Retain the full
/// live window in the moved buffer to preserve the same matches.
pub fn BtMatchfinder::move_down(self : BtMatchfinder, delta : Int32) -> Unit {
  guard delta >= 0 else { abort("BtMatchfinder: delta must be nonnegative") }
  bt_shift_positions(self.hash3, delta)
  bt_shift_positions(self.hash4, delta)
  bt_shift_positions(self.children, delta)
  // A node formerly in slot p & mask now belongs in (p-delta) & mask.
  // Rotate pairs in place, without allocating or changing the search path.
  let rotation = delta & self.tree_mask
  if rotation != 0 {
    let slots = self.children.length() / 2
    bt_reverse_nodes(self.children, 0, rotation)
    bt_reverse_nodes(self.children, rotation, slots)
    bt_reverse_nodes(self.children, 0, slots)
  }
}

///|
fn bt_shift_positions(table : FixedArray[Int32], delta : Int32) -> Unit {
  for i in 0..<table.length() {
    let position = table[i]
    // Test before subtracting, so even the empty sentinel cannot underflow.
    table[i] = if position >= delta { position - delta } else { BT_NO_POSITION }
  }
}

///|
// Reverse node slots, keeping each left/right child pair together.
fn bt_reverse_nodes(
  children : FixedArray[Int32],
  start : Int32,
  end : Int32,
) -> Unit {
  for lo = start, hi = end - 1; lo < hi; lo = lo + 1, hi = hi - 1 {
    let left = children[2 * lo]
    let right = children[2 * lo + 1]
    children[2 * lo] = children[2 * hi]
    children[2 * lo + 1] = children[2 * hi + 1]
    children[2 * hi] = left
    children[2 * hi + 1] = right
  }
}

///|
/// Inserts and searches `pos`. Requires 0 <= pos, 5 <= max_len <= data.length()
/// - pos, 4 <= nice_len <= max_len, and max_search_depth >= 1. Matches go into
/// `matches[2*i]` (length), `matches[2*i+1]` (offset); returns their count.
/// Provide at least 2*(nice_len-2) slots. Lengths strictly increase, offsets
/// do not decrease. Search stops at `nice_len` but extends the final match to
/// `max_len`. Neither this call nor `skip_byte` allocates.
pub fn BtMatchfinder::get_matches(
  self : BtMatchfinder,
  data : FixedArray[Byte],
  pos : Int32,
  max_len : Int32,
  nice_len : Int32,
  max_search_depth : Int32,
  matches : FixedArray[Int32],
) -> Int32 {
  self.advance(data, pos, max_len, nice_len, max_search_depth, matches, true)
}

///|
/// Inserts `pos` without recording matches, extending only to `nice_len` as
/// libdeflate's skip does. Requires 0 <= pos, 5 <= nice_len <= data.length()
/// - pos, max_search_depth >= 1, and sequential insertion as for `get_matches`.
pub fn BtMatchfinder::skip_byte(
  self : BtMatchfinder,
  data : FixedArray[Byte],
  pos : Int32,
  nice_len : Int32,
  max_search_depth : Int32,
) -> Unit {
  // With record=false the output is never accessed; reuse an existing array.
  ignore(
    self.advance(
      data,
      pos,
      nice_len,
      nice_len,
      max_search_depth,
      self.children,
      false,
    ),
  )
}

///|
// bt_matchfinder_advance_one_byte, in upstream order. Integer child slots
// replace its pending pointers. Inlining keeps the constant record flag and
// plain arrays on the hot path, including the skip specialization.
#inline
fn BtMatchfinder::advance(
  self : BtMatchfinder,
  data : FixedArray[Byte],
  pos : Int32,
  max_len : Int32,
  nice_len : Int32,
  max_search_depth : Int32,
  matches : FixedArray[Int32],
  record : Bool,
) -> Int32 {
  // Empty slots must stay out of reach even before a full window is present.
  let cutoff = (pos - self.max_distance).max(BT_NO_POSITION)
  let hash3 = self.next_hash3 * 2
  let hash4 = self.next_hash4
  // pos+5 <= data.length() is a caller precondition, hence both u32 loads
  // are within the buffer. Stored hashes are below their table sizes.
  let next_seq = load_u32(data, pos + 1)
  self.next_hash3 = hash_bits(next_seq & 0xFFFFFF, self.hash3_bits)
  self.next_hash4 = hash_bits(next_seq, self.hash4_bits)
  let first = read(self.hash3, hash3)
  let second = read(self.hash3, hash3 + 1)
  write(self.hash3, hash3, pos)
  write(self.hash3, hash3 + 1, first)
  let mut count = 0
  if record && first > cutoff {
    let seq3 = load_u32(data, pos) & 0xFFFFFF
    // Nodes above cutoff are nonnegative earlier buffer indices, so their
    // four-byte loads are valid too. Only the two latest hash3 ways are tried.
    let m = if seq3 == (load_u32(data, first) & 0xFFFFFF) {
      first
    } else if second > cutoff && seq3 == (load_u32(data, second) & 0xFFFFFF) {
      second
    } else {
      pos
    }
    if m != pos {
      // At most nice_len-2 pairs are emitted (one new length each time,
      // plus the final match), within the caller's output capacity.
      write(matches, 0, 3)
      write(matches, 1, pos - m)
      count = 1
    }
  }
  let mut node = read(self.hash4, hash4)
  write(self.hash4, hash4, pos)
  let children = self.children
  // Each node is masked into tree_size slots, with two children per slot.
  // All pending indices below therefore lie within children.length().
  let mut pending_lt = 2 * (pos & self.tree_mask)
  let mut pending_gt = pending_lt + 1
  let mut best_lt = 0
  let mut best_gt = 0
  let mut len = 0
  let mut best_len = 3
  let mut depth = max_search_depth
  while node > cutoff {
    // len is a known common prefix, below nice_len <= max_len. The earlier
    // node and pos both have max_len available. extend_match reads only that.
    if read(data, node + len) == read(data, pos + len) {
      len = extend_match(data, pos, node, len + 1, max_len)
      if !record || len > best_len {
        if record {
          best_len = len
          write(matches, 2 * count, len)
          write(matches, 2 * count + 1, pos - node)
          count += 1
        }
        if len >= nice_len {
          write(
            children,
            pending_lt,
            read(children, 2 * (node & self.tree_mask)),
          )
          write(
            children,
            pending_gt,
            read(children, 2 * (node & self.tree_mask) + 1),
          )
          return count
        }
      }
    }
    if read(data, node + len) < read(data, pos + len) {
      write(children, pending_lt, node)
      pending_lt = 2 * (node & self.tree_mask) + 1
      node = read(children, pending_lt)
      best_lt = len
      len = best_gt.min(len)
    } else {
      write(children, pending_gt, node)
      pending_gt = 2 * (node & self.tree_mask)
      node = read(children, pending_gt)
      best_gt = len
      len = best_lt.min(len)
    }
    depth -= 1
    if depth == 0 {
      break
    }
  }
  write(children, pending_lt, BT_NO_POSITION)
  write(children, pending_gt, BT_NO_POSITION)
  count
}
