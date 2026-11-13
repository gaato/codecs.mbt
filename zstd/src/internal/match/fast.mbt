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
/// windowLog. targetLength supplies the minimum search step, as fast's
/// acceleration does in the reference encoder.
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
  let mut p = start
  // Complete hashes that straddle the preceding block boundary only now:
  // their lookahead did not exist when that block was parsed.
  for q in (start - self.min_match + 1).max(0)..<start {
    if q + self.min_match <= end {
      self.hash[self.hash_at(q)] = q
    }
  }
  while p + self.min_match <= end {
    let h = self.hash_at(p)
    let candidate = self.hash[h]
    self.hash[h] = p
    let mut best = self.length(p, candidate, end)
    let mut distance = p - candidate
    let @seqenc.Distance(recent) = self.repeats.get(0)
    let @seqenc.Distance(second) = self.repeats.get(1)
    let immediate = if p == anchor && block.count > 0 {
      self.length(p, p - second.reinterpret_as_int(), end)
    } else {
      0
    }
    let ahead = p + 2
    let rep_length = self.length(
      ahead,
      ahead - recent.reinterpret_as_int(),
      end,
    )
    // Reference fast gives a recent-offset match two bytes ahead priority
    // over a hash match here. Two cheap literals often avoid a much more
    // expensive new offset; choosing only the longest match loses on nci.
    if immediate >= 4 {
      // The reference's immediate repeat-2 loop runs before restarting
      // the general search, where the zero-literal shift makes it code 1.
      best = immediate
      distance = second.reinterpret_as_int()
    } else if rep_length >= 4 {
      if p + 1 + self.min_match <= end {
        self.hash[self.hash_at(p + 1)] = p + 1
      }
      p = ahead
      best = rep_length
      distance = recent.reinterpret_as_int()
    }
    // Recent offsets are especially useful on the next sequence with no
    // literals; their eligibility is decided by seqenc's sole conversion.
    for r in 0..<3 {
      if immediate >= 4 || rep_length >= 4 {
        break
      }
      let @seqenc.Distance(d) = self.repeats.get(r)
      let len = self.length(p, p - d.reinterpret_as_int(), end)
      if len >= 4 && len > best {
        best = len
        distance = d.reinterpret_as_int()
      }
    }
    if best < 4 {
      p += self.acceleration + ((p - anchor) >> 8)
      continue
    }
    // Extend back over literals already skipped, within the frame/window.
    while p > anchor &&
          p - distance > 0 &&
          self.data[p - 1] == self.data[p - distance - 1] {
      p -= 1
      best += 1
    }
    let ll = p - anchor
    for i in anchor..<p {
      block.literal(self.data[i])
    }
    let raw = @seqenc.Distance(distance.reinterpret_as_uint())
    block.add(ll, best, raw)
    self.repeats.copy_from(block.repeats)
    let previous = p
    p += best
    anchor = p
    // Reference fast updates a few positions rather than every byte of a
    // long match: bounded work and a useful hash for its end.
    for q in [previous + 2, p - 2] {
      if q < p && q + self.min_match <= end {
        self.hash[self.hash_at(q)] = q
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
