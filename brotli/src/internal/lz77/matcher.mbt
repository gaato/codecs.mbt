// Generated from parts/lz77/matcher.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// A greedy LZ77 match finder over a caller-owned byte buffer. Positions are
// hashed by their first four bytes into buckets of the most recent few; a
// search compares the bucket's candidates and returns the longest match.
// The caller owns the buffer and may slide it down (`slide`).

///|
/// The shortest match a search returns: the bytes a hash covers.
pub const MIN_MATCH : Int32 = 4

///|
/// Candidates kept per hash bucket, newest first.
const BUCKET_SIZE : Int32 = 4

///|
/// The hash table of a match finder: a fixed `BUCKET_SIZE << hash_bits`
/// positions, whatever the buffer size.
pub struct Matcher {
  priv hash_bits : Int32
  // Positions plus one, newest first in each bucket; 0 is empty.
  priv table : FixedArray[Int32]
  // Positions below `next` have been hashed, as far as the data allowed.
  priv mut next : Int32
  priv mut distance : Int32
}

///|
/// A match finder with `1 << hash_bits` buckets (clamped to 8..20).
pub fn Matcher::Matcher(hash_bits~ : Int32 = 15) -> Matcher {
  let hash_bits = hash_bits.clamp(min=8, max=20)
  {
    hash_bits,
    table: FixedArray::make(BUCKET_SIZE << hash_bits, 0),
    next: 0,
    distance: 0,
  }
}

///|
/// Forgets every position, for a new buffer.
pub fn Matcher::reset(self : Matcher) -> Unit {
  self.table.fill(0)
  self.next = 0
  self.distance = 0
}

///|
/// The distance of the match the latest `find` returned.
pub fn Matcher::distance(self : Matcher) -> Int32 {
  self.distance
}

///|
/// The positions the table holds: one per bucket slot.
pub fn Matcher::capacity(self : Matcher) -> Int32 {
  self.table.length()
}

///|
fn Matcher::hash(self : Matcher, data : FixedArray[Byte], pos : Int32) -> Int32 {
  hash4(data, pos, self.hash_bits)
}

///|
fn Matcher::insert(
  self : Matcher,
  data : FixedArray[Byte],
  pos : Int32,
) -> Unit {
  let base = self.hash(data, pos) * BUCKET_SIZE
  let table = self.table
  for i = BUCKET_SIZE - 1; i > 0; i = i - 1 {
    table[base + i] = table[base + i - 1]
  }
  table[base] = pos + 1
}

///|
/// The longest match for `data[pos..end)` at most `max_distance` back and
/// at most `max_length` long: its length, at least `MIN_MATCH`, or 0 for
/// none; `distance` gives its distance. Every position from the previous
/// search up to `pos` is hashed first, so positions inside matches are
/// found later too. Calls must come with increasing `pos`, over the same
/// buffer contents (up to `slide`).
pub fn Matcher::find(
  self : Matcher,
  data : FixedArray[Byte],
  pos : Int32,
  end : Int32,
  max_distance : Int32,
  max_length : Int32,
) -> Int32 {
  while self.next < pos && self.next + MIN_MATCH <= end {
    self.insert(data, self.next)
    self.next += 1
  }
  let limit = max_length.min(end - pos)
  guard self.next == pos && limit >= MIN_MATCH else { return 0 }
  let base = self.hash(data, pos) * BUCKET_SIZE
  let mut best = 0
  for i in 0..<BUCKET_SIZE {
    let candidate = self.table[base + i] - 1
    let dist = pos - candidate
    if candidate < 0 || dist > max_distance {
      break
    }
    // Check the byte that would make it longer than the best first.
    if data[candidate + best] != data[pos + best] {
      continue
    }
    let len = match_length(data, candidate, pos, limit)
    if len > best {
      best = len
      self.distance = dist
      if len == limit {
        break
      }
    }
  }
  self.insert(data, pos)
  self.next = pos + 1
  if best >= MIN_MATCH {
    best
  } else {
    0
  }
}

///|
/// Moves every position down by `shift`, after the caller moved its buffer
/// down by as much; positions below `shift` are dropped.
pub fn Matcher::slide(self : Matcher, shift : Int32) -> Unit {
  let table = self.table
  for i in 0..<table.length() {
    table[i] = if table[i] > shift { table[i] - shift } else { 0 }
  }
  self.next = (self.next - shift).max(0)
}
