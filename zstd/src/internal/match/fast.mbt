///|
/// One hash table and a bounded sliding window. Positions are relative to
/// the retained window, rebased at block boundaries, so arbitrarily long
/// frames cannot overflow a position counter.
pub struct Fast {
  priv hash : FixedArray[Int32]
  priv hash_log : Int32
  priv window : Int32
  priv min_match : Int32
  priv acceleration : Int32
  priv mut data : FixedArray[Byte]
  priv mut history : Int32
  priv repeats : @seqenc.Repeats
}

///|
/// A fast finder with the level's hashLog, minMatch, targetLength and
/// windowLog. The gap between search pairs starts at max(targetLength, 1)
/// plus one, as in the reference encoder.
pub fn Fast::Fast(
  hash_log~ : Int32,
  min_match~ : Int32,
  target_length~ : Int32,
  window_log~ : Int32,
) -> Fast {
  {
    hash: FixedArray::make(1 << hash_log, -1),
    hash_log,
    window: 1 << window_log,
    min_match: min_match.clamp(min=4, max=7),
    acceleration: target_length.max(1),
    data: [],
    history: 0,
    repeats: @seqenc.Repeats(),
  }
}

///|
/// Starts another frame; no previous frame bytes may be referenced.
pub fn Fast::reset(self : Fast) -> Unit {
  self.hash.fill(-1)
  self.data = []
  self.history = 0
  self.repeats.reset()
}

///|
fn Fast::hash_at(self : Fast, pos : Int32) -> Int32 {
  let mut word = 0UL
  for i in 0..<self.min_match {
    word = word | (self.data[pos + i].to_uint64() << (i * 8))
  }
  // Reference ZSTD_hash{4,5,6,7}; minMatch selects the hash width. The
  // subsequent byte comparison may accept a four-byte match even when
  // hashing more bytes, just as ZSTD_compressBlock_fast does.
  if self.min_match == 4 {
    ((word.to_uint() * 2654435761U) >> (32 - self.hash_log)).reinterpret_as_int()
  } else {
    let prime = match self.min_match {
      5 => 889523592379UL
      6 => 227718039650203UL
      _ => 58295818150454627UL
    }
    (((word << (64 - self.min_match * 8)) * prime) >> (64 - self.hash_log)).to_int()
  }
}

///|
fn Fast::length(self : Fast, p : Int32, q : Int32, end : Int32) -> Int32 {
  if q < 0 || q >= p || p - q > self.window {
    return 0
  }
  let mut n = 0
  while p + n < end && self.data[p + n] == self.data[q + n] {
    n += 1
  }
  n
}

///|
/// Finds matches for exactly one cutter block. Hash and bytes advance even
/// if the caller eventually stores that block raw or RLE. Repeat history
/// is copied from the committed sequence writer, never from a rejected
/// candidate. `block` receives concatenated literals and coded offsets.
pub fn Fast::find(
  self : Fast,
  input : FixedArray[Byte],
  n : Int32,
  repeats : @seqenc.Repeats,
  block : @seqenc.Block,
) -> Unit {
  let start = self.history
  let end = start + n
  if self.data.length() < end {
    let grown = FixedArray::make(
      end.max(self.data.length() * 2).min(self.window + 131072),
      b'\x00',
    )
    FixedArray::unsafe_blit(grown, 0, self.data, 0, start)
    self.data = grown
  }
  FixedArray::unsafe_blit(self.data, start, input, 0, n)
  block.reset(repeats, n)
  self.repeats.copy_from(repeats)
  let mut anchor = start
  let mut p = start.max(1)
  let @seqenc.Distance(first) = self.repeats.get(0)
  let @seqenc.Distance(second) = self.repeats.get(1)
  let mut rep1 = if first.reinterpret_as_int() <= p {
    first.reinterpret_as_int()
  } else {
    0
  }
  let mut rep2 = if second.reinterpret_as_int() <= p {
    second.reinterpret_as_int()
  } else {
    0
  }
  // ZSTD_compressBlock_fast_noDict_generic, v1.5.7. Pairs of adjacent
  // positions share an accelerating step. Preserve the pipeline's
  // lookup/insertion order even though the loads here are checked.
  let limit = end - 8
  while p < limit {
    let mut step = self.acceleration + 1
    let mut next_step = p + 128
    let mut p1 = p + 1
    let mut p2 = p + step
    let mut p3 = p2 + 1
    if p3 >= limit {
      break
    }
    let mut h0 = self.hash_at(p)
    let mut h1 = self.hash_at(p1)
    let mut candidate = self.hash[h0]
    let mut current = p
    let mut best = 0
    let mut distance = 0
    let mut is_repeat = false
    while p3 < limit {
      current = p
      self.hash[h0] = p
      if rep1 > 0 {
        best = self.length(p2, p2 - rep1, end)
        if best >= 4 {
          p = p2
          distance = rep1
          is_repeat = true
          // A repeat catches back at most one byte, unlike a hash match.
          if p - distance > 0 && self.data[p - 1] == self.data[p - distance - 1] {
            p -= 1
            best += 1
          }
          self.hash[h1] = p1
          break
        }
      }
      best = self.length(p, candidate, end)
      if best >= 4 {
        distance = p - candidate
        self.hash[h1] = p1
        break
      }
      candidate = self.hash[h1]
      h0 = h1
      h1 = self.hash_at(p2)
      p = p1
      p1 = p2
      p2 = p3
      current = p
      self.hash[h0] = p
      best = self.length(p, candidate, end)
      if best >= 4 {
        distance = p - candidate
        if step <= 4 {
          self.hash[h1] = p1
        }
        break
      }
      candidate = self.hash[h1]
      h0 = h1
      h1 = self.hash_at(p2)
      p = p1
      p1 = p2
      p2 = p + step
      p3 = p1 + step
      if p2 >= next_step {
        step += 1
        next_step += 128
      }
    }
    if distance == 0 {
      break
    }
    if !is_repeat {
      rep2 = rep1
      rep1 = distance
      while p > anchor &&
            p - distance > 0 &&
            self.data[p - 1] == self.data[p - distance - 1] {
        p -= 1
        best += 1
      }
    }
    for i in anchor..<p {
      block.literal(self.data[i])
    }
    block.add(
      p - anchor,
      best,
      @seqenc.Distance(distance.reinterpret_as_uint()),
    )
    p += best
    anchor = p
    if p <= limit {
      self.hash[self.hash_at(current + 2)] = current + 2
      self.hash[self.hash_at(p - 2)] = p - 2
      while p <= limit && rep2 > 0 {
        let len = self.length(p, p - rep2, end)
        if len < 4 {
          break
        }
        self.hash[self.hash_at(p)] = p
        block.add(0, len, @seqenc.Distance(rep2.reinterpret_as_uint()))
        let old = rep1
        rep1 = rep2
        rep2 = old
        p += len
        anchor = p
      }
    }
  }
  for i in anchor..<end {
    block.literal(self.data[i])
  }
  let drop = (end - self.window).max(0)
  if drop > 0 {
    // Forward copy is safe for overlapping regions.
    for i in drop..<end {
      self.data[i - drop] = self.data[i]
    }
    for i in 0..<self.hash.length() {
      self.hash[i] = (self.hash[i] - drop).max(-1)
    }
  }
  self.history = end - drop
}

///|
/// Window allocation (at most window + one block), hash table and repeats.
pub fn Fast::memory_usage(self : Fast) -> Int32 {
  self.data.length() + 4 * self.hash.length() + 12
}
