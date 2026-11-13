///|
/// Hash-chain search and the reference greedy/lazy/lazy2 parser (depth 0/1/2).
/// Positions are relative to retained history; a ring bias preserves chain
/// slots when byte positions rebase, without moving the chain table.
#cfg(any(target="native", target="wasm"))
pub struct Lazy {
  priv hash : FixedArray[Int32]
  priv chain : FixedArray[Int32]
  priv hash_log : Int32
  priv hash_shift : Int32
  priv hash_prime : UInt64
  priv attempts : Int32
  priv depth : Int32
  priv window : Int32
  priv history : History
  priv mut next_update : Int32
  priv mut bias : Int32
  // Search results live here: returning a tuple allocates a box per search
  // on native. Each search overwrites both, including the no-match case.
  priv mut match_length : Int32
  priv mut match_distance : Int32
}

///|
/// Original checked-target layout, without the native/Wasm multiplier.
#cfg(not(any(target="native", target="wasm")))
pub struct Lazy {
  priv hash : FixedArray[Int32]
  priv chain : FixedArray[Int32]
  priv hash_log : Int32
  priv min_match : Int32
  priv attempts : Int32
  priv depth : Int32
  priv window : Int32
  priv history : History
  priv mut next_update : Int32
  priv mut bias : Int32
  priv mut match_length : Int32
  priv mut match_distance : Int32
}

///|
/// Allocates 2^hashLog heads and 2^chainLog links. Search examines at most
/// 2^searchLog candidates. As in ZSTD_HcFindBestMatch, minMatch selects a
/// 4..6 byte hash, while four-byte matches remain eligible. targetLength
/// is not an early-exit threshold in the reference hash-chain search.
#cfg(any(target="native", target="wasm"))
pub fn Lazy::Lazy(
  hash_log~ : Int32,
  chain_log~ : Int32,
  min_match~ : Int32,
  search_log~ : Int32,
  depth~ : Int32,
  window_log~ : Int32,
) -> Lazy {
  let hash = FixedArray::make(1 << hash_log, -1)
  let chain = FixedArray::make(1 << chain_log, -1)
  {
    hash,
    chain,
    hash_log,
    hash_shift: 64 - min_match.clamp(min=4, max=6) * 8,
    hash_prime: hash_prime(min_match.clamp(min=4, max=6)),
    attempts: 1 << search_log,
    depth,
    window: 1 << window_log,
    history: History::new(1 << window_log, hash, chain),
    next_update: 0,
    bias: 0,
    match_length: 3,
    match_distance: 0,
  }
}

///|
/// The same finder with the original checked-target representation.
#cfg(not(any(target="native", target="wasm")))
pub fn Lazy::Lazy(
  hash_log~ : Int32,
  chain_log~ : Int32,
  min_match~ : Int32,
  search_log~ : Int32,
  depth~ : Int32,
  window_log~ : Int32,
) -> Lazy {
  let hash = FixedArray::make(1 << hash_log, -1)
  let chain = FixedArray::make(1 << chain_log, -1)
  {
    hash,
    chain,
    hash_log,
    min_match: min_match.clamp(min=4, max=6),
    attempts: 1 << search_log,
    depth,
    window: 1 << window_log,
    history: History::new(1 << window_log, hash, chain),
    next_update: 0,
    bias: 0,
    match_length: 3,
    match_distance: 0,
  }
}

///|
/// Invalidates all frame positions and releases retained bytes.
pub fn Lazy::reset(self : Lazy) -> Unit {
  self.history.reset()
  self.next_update = 0
  self.bias = 0
}

///|
#cfg(any(target="native", target="wasm"))
#inline
fn Lazy::hash_at(self : Lazy, p : Int32) -> Int32 {
  // search's p <= end - 8; catch-up insertion i < p has more lookahead.
  (((load64(self.history.data, p) << self.hash_shift) * self.hash_prime) >>
  (64 - self.hash_log)).to_int()
}

///|
#cfg(not(any(target="native", target="wasm")))
fn Lazy::hash_at(self : Lazy, p : Int32) -> Int32 {
  let mut word = 0UL
  for i in 0..<self.min_match {
    word = word | (self.history.data[p + i].to_uint64() << (8 * i))
  }
  if self.min_match == 4 {
    ((word.to_uint() * 2654435761U) >> (32 - self.hash_log)).reinterpret_as_int()
  } else {
    let prime = if self.min_match == 5 {
      889523592379UL
    } else {
      227718039650203UL
    }
    (((word << (64 - self.min_match * 8)) * prime) >> (64 - self.hash_log)).to_int()
  }
}

///|
fn Lazy::slot(self : Lazy, p : Int32) -> Int32 {
  (p + self.bias) & (self.chain.length() - 1)
}

///|
fn Lazy::length(self : Lazy, p : Int32, q : Int32, end : Int32) -> Int32 {
  if q < 0 || q >= p || p - q > self.window {
    return 0
  }
  match_length(self.history.data, p, q, end)
}

///|
/// Catch up to, but exclude, p. Lazy skipping inserts only the previous
/// searched position after an incompressible gap exceeding 2 KiB.
fn Lazy::search(self : Lazy, p : Int32, end : Int32, skipping : Bool) -> Unit {
  let mut i = self.next_update
  while i < p {
    let h = self.hash_at(i)
    // h fits hash_log bits; slot masks to chain.length() - 1.
    write(self.chain, self.slot(i), read(self.hash, h))
    write(self.hash, h, i)
    i += 1
    if skipping {
      break
    }
  }
  self.next_update = p
  // The hash result fits the power-of-two head table.
  let mut q = read(self.hash, self.hash_at(p))
  let low = (p - self.window).max(0)
  let min_chain = (p - self.chain.length()).max(
    (self.history.start - self.window).max(0),
  )
  let mut best = 3
  let mut distance = 0
  let mut attempts = self.attempts
  while q >= low && q < p && attempts > 0 {
    // The reference tests four bytes at the current best's tail before
    // recounting from the start; this avoids quadratic work on long ties.
    let n = if may_beat(self.history.data, p, q, best) {
      self.length(p, q, end)
    } else {
      0
    }
    if n > best {
      best = n
      distance = p - q
      if p + n == end {
        break
      }
    }
    if q <= min_chain {
      break
    }
    // slot masks to chain.length() - 1; the link is not yet overwritten.
    q = read(self.chain, self.slot(q))
    attempts -= 1
  }
  self.match_length = best
  self.match_distance = distance
}

///|
fn offset_bits(distance : Int32) -> Int32 {
  // Our zero distance sentinel means repeat one: reference offBase=1,
  // whose high bit is zero. A new offset has offBase=distance+3.
  if distance == 0 {
    0
  } else {
    31 - (distance + 3).clz()
  }
}

///|
/// Parses complete cutter blocks, retaining raw/RLE history. Only the
/// committed writer supplies repeats; step boundaries never affect search.
pub fn Lazy::find(
  self : Lazy,
  input : FixedArray[Byte],
  n : Int32,
  repeats : @seqenc.Repeats,
  block : @seqenc.Block,
) -> Unit {
  self.prepare(self.window.min(131072))
  self.history.append_fixed(input, n)
  self.find_buffered(n, repeats, block)
  self.history.finish_block()
}

///|
/// Parses bytes already appended to the shared history by the block cutter.
pub fn Lazy::find_buffered(
  self : Lazy,
  n : Int32,
  repeats : @seqenc.Repeats,
  block : @seqenc.Block,
) -> Unit {
  let start = self.history.start
  let end = start + n
  let floor = (start - self.window).max(0)
  // The old per-block slide clipped this cursor even when no bytes were
  // inserted. Keep the same logical floor while physical sliding is delayed.
  self.next_update = self.next_update.max(floor)
  block.reset(repeats, n)
  let mut anchor = start
  let mut p = start.max(1)
  let @seqenc.Distance(first) = repeats.get(0)
  let @seqenc.Distance(second) = repeats.get(1)
  let mut rep1 = if first.reinterpret_as_int() <= p.min(self.window) {
    first.reinterpret_as_int()
  } else {
    0
  }
  let mut rep2 = if second.reinterpret_as_int() <= p.min(self.window) {
    second.reinterpret_as_int()
  } else {
    0
  }
  let mut skipping = false
  while p < end - 8 {
    let mut best = if rep1 > 0 {
      self.length(p + 1, p + 1 - rep1, end)
    } else {
      0
    }
    if best < 4 {
      best = 0
    }
    let mut chosen = p + 1
    // Zero denotes a repeat search decision, not a zero raw distance.
    let mut distance = 0
    if self.depth != 0 || best == 0 {
      self.search(p, end, skipping)
      let len = self.match_length
      let d = self.match_distance
      if len > best {
        best = len
        chosen = p
        distance = d
      }
      if best < 4 {
        let step = ((p - anchor) >> 8) + 1
        p += step
        skipping = step > 8
        continue
      }
      if self.depth >= 1 {
        while p < end - 8 {
          p += 1
          // An already selected repeat cannot improve at the same or a
          // later byte with the same distance, so omit that redundant check.
          if distance != 0 && rep1 > 0 {
            let len = self.length(p, p - rep1, end)
            if len >= 4 && len * 3 > best * 3 - offset_bits(distance) + 1 {
              best = len
              distance = 0
              chosen = p
            }
          }
          self.search(p, end, skipping)
          let len = self.match_length
          let d = self.match_distance
          if len >= 4 &&
            len * 4 - offset_bits(d) > best * 4 - offset_bits(distance) + 4 {
            best = len
            distance = d
            chosen = p
            continue
          }
          if self.depth == 2 && p < end - 8 {
            p += 1
            if distance != 0 && rep1 > 0 {
              let len = self.length(p, p - rep1, end)
              if len >= 4 && len * 4 > best * 4 - offset_bits(distance) + 1 {
                best = len
                distance = 0
                chosen = p
              }
            }
            self.search(p, end, skipping)
            let len = self.match_length
            let d = self.match_distance
            if len >= 4 &&
              len * 4 - offset_bits(d) > best * 4 - offset_bits(distance) + 7 {
              best = len
              distance = d
              chosen = p
              continue
            }
          }
          break
        }
      }
      if distance != 0 {
        while chosen > anchor &&
              chosen - distance > floor &&
              // 0 < chosen - distance <= chosen < end: predecessors fit.
              read(self.history.data, chosen - 1) ==
              read(self.history.data, chosen - distance - 1) {
          chosen -= 1
          best += 1
        }
        rep2 = rep1
        rep1 = distance
      }
    }
    // anchor <= chosen <= end <= the buffer's length.
    block.literals_from(self.history.data, anchor, chosen)
    block.add(
      chosen - anchor,
      best,
      @seqenc.Distance(rep1.reinterpret_as_uint()),
    )
    p = chosen + best
    anchor = p
    skipping = false
    while p <= end - 8 && rep2 > 0 {
      let len = self.length(p, p - rep2, end)
      if len < 4 {
        break
      }
      block.add(0, len, @seqenc.Distance(rep2.reinterpret_as_uint()))
      let old = rep1
      rep1 = rep2
      rep2 = old
      p += len
      anchor = p
    }
  }
  // anchor <= end <= the buffer's length.
  block.literals_from(self.history.data, anchor, end)
}

///|
/// Retained byte capacity plus four bytes per hash head and chain link.
pub fn Lazy::memory_usage(self : Lazy) -> Int32 {
  self.history.data.length() + 4 * (self.hash.length() + self.chain.length())
}

///|
/// Shared input storage; append only after reserving the next cutter block.
pub fn Lazy::history(self : Lazy) -> History {
  self.history
}

///|
/// Makes room for a whole cutter block, independently of input step sizes.
pub fn Lazy::prepare(self : Lazy, block_max : Int32) -> Unit {
  let cut = self.history.prepare(block_max)
  self.bias = (self.bias + cut) & (self.chain.length() - 1)
  self.next_update = (self.next_update - cut).max(0)
}
