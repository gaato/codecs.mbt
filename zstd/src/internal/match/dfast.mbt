///|
/// Double-fast matching: an eight-byte hash and a minMatch hash, with
/// rebased positions in a bounded sliding window, as in the fast finder.
#cfg(any(target="native", target="wasm"))
pub struct Dfast {
  priv long : FixedArray[Int32]
  priv short : FixedArray[Int32]
  priv hash_log : Int32
  priv chain_log : Int32
  priv hash_shift : Int32
  priv hash_prime : UInt64
  priv window : Int32
  priv mut data : FixedArray[Byte]
  priv mut history : Int32
}

///|
/// Original checked-target layout, without the native/Wasm multiplier.
#cfg(not(any(target="native", target="wasm")))
pub struct Dfast {
  priv long : FixedArray[Int32]
  priv short : FixedArray[Int32]
  priv hash_log : Int32
  priv chain_log : Int32
  priv min_match : Int32
  priv window : Int32
  priv mut data : FixedArray[Byte]
  priv mut history : Int32
}

///|
/// Uses hashLog for the long table and chainLog for the short table, as
/// ZSTD_compressBlock_doubleFast does. Its search step starts at one.
#cfg(any(target="native", target="wasm"))
pub fn Dfast::Dfast(
  hash_log~ : Int32,
  chain_log~ : Int32,
  min_match~ : Int32,
  window_log~ : Int32,
) -> Dfast {
  {
    long: FixedArray::make(1 << hash_log, -1),
    short: FixedArray::make(1 << chain_log, -1),
    hash_log,
    chain_log,
    hash_shift: 64 - min_match.clamp(min=4, max=7) * 8,
    hash_prime: hash_prime(min_match.clamp(min=4, max=7)),
    window: 1 << window_log,
    data: [],
    history: 0,
  }
}

///|
/// The same finder with the original checked-target representation.
#cfg(not(any(target="native", target="wasm")))
pub fn Dfast::Dfast(
  hash_log~ : Int32,
  chain_log~ : Int32,
  min_match~ : Int32,
  window_log~ : Int32,
) -> Dfast {
  {
    long: FixedArray::make(1 << hash_log, -1),
    short: FixedArray::make(1 << chain_log, -1),
    hash_log,
    chain_log,
    min_match: min_match.clamp(min=4, max=7),
    window: 1 << window_log,
    data: [],
    history: 0,
  }
}

///|
/// Releases frame history and invalidates both tables before another frame.
pub fn Dfast::reset(self : Dfast) -> Unit {
  self.long.fill(-1)
  self.short.fill(-1)
  self.data = []
  self.history = 0
}

///|
#cfg(not(any(target="native", target="wasm")))
fn Dfast::hash_at(self : Dfast, p : Int32, width : Int32, log : Int32) -> Int32 {
  let mut word = 0UL
  for i in 0..<width {
    word = word | (self.data[p + i].to_uint64() << (8 * i))
  }
  if width == 4 {
    ((word.to_uint() * 2654435761U) >> (32 - log)).reinterpret_as_int()
  } else {
    let prime = match width {
      5 => 889523592379UL
      6 => 227718039650203UL
      7 => 58295818150454627UL
      _ => 0xcf1bbcdcb7a56463UL
    }
    (((word << (64 - width * 8)) * prime) >> (64 - log)).to_int()
  }
}

///|
#cfg(any(target="native", target="wasm"))
#inline
fn Dfast::long_hash(self : Dfast, p : Int32) -> Int32 {
  // All callers leave eight bytes through end (including tail catch-up).
  ((load64(self.data, p) * 0xcf1bbcdcb7a56463UL) >> (64 - self.hash_log)).to_int()
}

///|
#cfg(any(target="native", target="wasm"))
#inline
fn Dfast::short_hash(self : Dfast, p : Int32) -> Int32 {
  // p - 1 after a match precedes an end checked to leave eight bytes.
  (((load64(self.data, p) << self.hash_shift) * self.hash_prime) >>
  (64 - self.chain_log)).to_int()
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn Dfast::long_hash(self : Dfast, p : Int32) -> Int32 {
  self.hash_at(p, 8, self.hash_log)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn Dfast::short_hash(self : Dfast, p : Int32) -> Int32 {
  self.hash_at(p, self.min_match, self.chain_log)
}

///|
fn Dfast::length(self : Dfast, p : Int32, q : Int32, end : Int32) -> Int32 {
  if q < 0 || q >= p || p - q > self.window {
    return 0
  }
  match_length(self.data, p, q, end)
}

///|
fn Dfast::insert(self : Dfast, p : Int32) -> Unit {
  // Hashes are strictly below their power-of-two table lengths.
  write(self.long, self.long_hash(p), p)
  write(self.short, self.short_hash(p), p)
}

///|
/// Parses one complete cutter block. Both tables retain raw/RLE history;
/// repeats come only from the committed writer, so rejected blocks cannot
/// change the frame's repeat offsets. Input step boundaries are invisible.
pub fn Dfast::find(
  self : Dfast,
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
  for q in (start - 7).max(0)..<start {
    if q + 8 <= end {
      self.insert(q)
    }
  }
  let mut anchor = start
  let mut p = start.max(1)
  let @seqenc.Distance(first) = repeats.get(0)
  let @seqenc.Distance(second) = repeats.get(1)
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
  // Scalar transcription of the reference no-dictionary pipeline. Keep the
  // current long candidate from before insertion; load the next candidate
  // after inserting the current position, including collisions.
  // kSearchStrength is eight.
  while p + 9 <= end {
    let mut step = 1
    let mut next_step = p + 256
    let mut next = p + step
    let mut hl = self.long_hash(p)
    // hl has hash_log bits, exactly the table's index range.
    let mut long = read(self.long, hl)
    let mut best = 0
    let mut distance = 0
    let mut current = p
    let mut is_repeat = false
    while next + 8 <= end {
      current = p
      let hs = self.short_hash(p)
      // hs and hl have chain_log and hash_log bits respectively.
      let short = read(self.short, hs)
      write(self.long, hl, p)
      write(self.short, hs, p)
      if rep1 > 0 {
        let len = self.length(p + 1, p + 1 - rep1, end)
        if len >= 4 {
          p += 1
          best = len
          distance = rep1
          is_repeat = true
          break
        }
      }
      let next_hl = self.long_hash(next)
      best = self.length(p, long, end)
      if best >= 8 {
        distance = p - long
      } else {
        // next_hl is a hash_log-bit index into long.
        let next_long = read(self.long, next_hl)
        best = self.length(p, short, end)
        if best >= 4 {
          distance = p - short
          let ahead = self.length(next, next_long, end)
          if ahead >= 8 && ahead > best {
            p = next
            best = ahead
            distance = p - next_long
          }
        } else {
          if next >= next_step {
            step += 1
            next_step += 256
          }
          p = next
          next += step
          hl = next_hl
          long = next_long
          continue
        }
      }
      while p > anchor &&
            p - distance > 0 &&
            // 0 < p - distance <= p < end, so both predecessors fit.
            read(self.data, p - 1) == read(self.data, p - distance - 1) {
        p -= 1
        best += 1
      }
      if step < 4 {
        // next_hl is a hash_log-bit index into long.
        write(self.long, next_hl, next)
      }
      break
    }
    if distance == 0 {
      break
    }
    for i in anchor..<p {
      // anchor <= i < p <= end.
      block.literal(read(self.data, i))
    }
    block.add(
      p - anchor,
      best,
      @seqenc.Distance(distance.reinterpret_as_uint()),
    )
    if !is_repeat {
      rep2 = rep1
      rep1 = distance
    }
    p += best
    anchor = p
    if p + 8 <= end {
      self.insert(current + 2)
      // Each hash fits its own table; both positions precede p <= end - 8.
      write(self.long, self.long_hash(p - 2), p - 2)
      write(self.short, self.short_hash(p - 1), p - 1)
      while p + 8 <= end && rep2 > 0 {
        let len = self.length(p, p - rep2, end)
        if len < 4 {
          break
        }
        self.insert(p)
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
    // anchor <= i < end.
    block.literal(read(self.data, i))
  }
  let drop = (end - self.window).max(0)
  if drop > 0 {
    for i in drop..<end {
      self.data[i - drop] = self.data[i]
    }
    // Separate loops avoid allocating an array of tables at each rebase.
    for i in 0..<self.long.length() {
      self.long[i] = (self.long[i] - drop).max(-1)
    }
    for i in 0..<self.short.length() {
      self.short[i] = (self.short[i] - drop).max(-1)
    }
  }
  self.history = end - drop
}

///|
/// Retained bytes and both four-byte position tables.
pub fn Dfast::memory_usage(self : Dfast) -> Int32 {
  self.data.length() + 4 * (self.long.length() + self.short.length())
}
