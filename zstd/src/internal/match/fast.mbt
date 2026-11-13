///|
/// One hash table and a bounded sliding window. Positions are relative to
/// the retained window, rebased at block boundaries, so arbitrarily long
/// frames cannot overflow a position counter.
#cfg(any(target="native", target="wasm"))
pub struct Fast {
  priv hash : FixedArray[Int32]
  priv hash_log : Int32
  priv window : Int32
  priv hash_shift : Int32
  priv hash_prime : UInt64
  priv acceleration : Int32
  priv history : History
  priv repeats : @seqenc.Repeats
}

///|
/// The checked targets keep byte-wise hashes without wide-hash fields:
/// even an unused multiplier can affect Wasm GC's object layout.
#cfg(not(any(target="native", target="wasm")))
pub struct Fast {
  priv hash : FixedArray[Int32]
  priv hash_log : Int32
  priv window : Int32
  priv min_match : Int32
  priv acceleration : Int32
  priv history : History
  priv repeats : @seqenc.Repeats
}

///|
/// A fast finder with the level's hashLog, minMatch, targetLength and
/// windowLog. The gap between search pairs starts at max(targetLength, 1)
/// plus one, as in the reference encoder.
#cfg(any(target="native", target="wasm"))
pub fn Fast::Fast(
  hash_log~ : Int32,
  min_match~ : Int32,
  target_length~ : Int32,
  window_log~ : Int32,
) -> Fast {
  let hash = FixedArray::make(1 << hash_log, -1)
  {
    hash,
    hash_log,
    window: 1 << window_log,
    hash_shift: 64 - min_match.clamp(min=4, max=7) * 8,
    hash_prime: hash_prime(min_match.clamp(min=4, max=7)),
    acceleration: target_length.max(1),
    history: History::new(1 << window_log, hash, []),
    repeats: @seqenc.Repeats(),
  }
}

///|
/// The same finder with the original checked-target representation.
#cfg(not(any(target="native", target="wasm")))
pub fn Fast::Fast(
  hash_log~ : Int32,
  min_match~ : Int32,
  target_length~ : Int32,
  window_log~ : Int32,
) -> Fast {
  let hash = FixedArray::make(1 << hash_log, -1)
  {
    hash,
    hash_log,
    window: 1 << window_log,
    min_match: min_match.clamp(min=4, max=7),
    acceleration: target_length.max(1),
    history: History::new(1 << window_log, hash, []),
    repeats: @seqenc.Repeats(),
  }
}

///|
/// Starts another frame; no previous frame bytes may be referenced.
pub fn Fast::reset(self : Fast) -> Unit {
  self.history.reset()
  self.repeats.reset()
}

///|
#cfg(any(target="native", target="wasm"))
#inline
fn Fast::hash_at(self : Fast, pos : Int32) -> Int32 {
  // Searches leave eight valid bytes; post-match insertions are no later
  // than the match end, itself checked against end - 8.
  let word = load64(self.history.data, pos)
  // For width 4, shifting first keeps exactly the low 32-bit product in
  // the high half, reproducing ZSTD_hash4's UInt32 wrap and final shift.
  (((word << self.hash_shift) * self.hash_prime) >> (64 - self.hash_log)).to_int()
}

///|
#cfg(not(any(target="native", target="wasm")))
fn Fast::hash_at(self : Fast, pos : Int32) -> Int32 {
  let mut word = 0UL
  for i in 0..<self.min_match {
    word = word | (self.history.data[pos + i].to_uint64() << (i * 8))
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
  match_length(self.history.data, p, q, end)
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
  self.prepare(self.window.min(131072))
  self.history.append_fixed(input, n)
  self.find_buffered(n, repeats, block)
  self.history.finish_block()
}

///|
/// Parses bytes already appended to the shared history by the block cutter.
pub fn Fast::find_buffered(
  self : Fast,
  n : Int32,
  repeats : @seqenc.Repeats,
  block : @seqenc.Block,
) -> Unit {
  let start = self.history.start
  let end = start + n
  // Delayed physical slides must not extend matches into bytes the old
  // per-block slide had discarded. Repeat eligibility uses this floor too.
  let floor = (start - self.window).max(0)
  block.reset(repeats, n)
  self.repeats.copy_from(repeats)
  let mut anchor = start
  let mut p = start.max(1)
  let @seqenc.Distance(first) = self.repeats.get(0)
  let @seqenc.Distance(second) = self.repeats.get(1)
  let mut rep1 = if first.reinterpret_as_int() <= p - floor {
    first.reinterpret_as_int()
  } else {
    0
  }
  let mut rep2 = if second.reinterpret_as_int() <= p - floor {
    second.reinterpret_as_int()
  } else {
    0
  }
  // ZSTD_compressBlock_fast_noDict_generic, v1.5.7. Pairs of adjacent
  // positions share an accelerating step. Preserve the pipeline's
  // lookup/insertion order. All searched positions leave eight valid bytes.
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
    // h0/h1 contain hash_log bits, so they fit the hash table.
    let mut candidate = read(self.hash, h0)
    let mut current = p
    let mut best = 0
    let mut distance = 0
    let mut is_repeat = false
    while p3 < limit {
      current = p
      // h0/h1 contain hash_log bits, so all pipeline table accesses fit.
      write(self.hash, h0, p)
      if rep1 > 0 {
        best = self.length(p2, p2 - rep1, end)
        if best >= 4 {
          p = p2
          distance = rep1
          is_repeat = true
          // A repeat catches back at most one byte, unlike a hash match.
          // 0 < p - distance <= p < end, so both predecessors fit.
          if p - distance > floor &&
            read(self.history.data, p - 1) ==
            read(self.history.data, p - distance - 1) {
            p -= 1
            best += 1
          }
          write(self.hash, h1, p1)
          break
        }
      }
      best = self.length(p, candidate, end)
      if best >= 4 {
        distance = p - candidate
        write(self.hash, h1, p1)
        break
      }
      candidate = read(self.hash, h1)
      h0 = h1
      h1 = self.hash_at(p2)
      p = p1
      p1 = p2
      p2 = p3
      current = p
      write(self.hash, h0, p)
      best = self.length(p, candidate, end)
      if best >= 4 {
        distance = p - candidate
        if step <= 4 {
          write(self.hash, h1, p1)
        }
        break
      }
      candidate = read(self.hash, h1)
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
            p - distance > floor &&
            // 0 < p - distance <= p < end, so both predecessors fit.
            read(self.history.data, p - 1) ==
            read(self.history.data, p - distance - 1) {
        p -= 1
        best += 1
      }
    }
    // anchor <= p <= end <= the buffer's length.
    block.literals_from(self.history.data, anchor, p)
    block.add(
      p - anchor,
      best,
      @seqenc.Distance(distance.reinterpret_as_uint()),
    )
    p += best
    anchor = p
    if p <= limit {
      // Hash results fit the table; current + 2 <= p <= end - 8.
      write(self.hash, self.hash_at(current + 2), current + 2)
      write(self.hash, self.hash_at(p - 2), p - 2)
      while p <= limit && rep2 > 0 {
        let len = self.length(p, p - rep2, end)
        if len < 4 {
          break
        }
        // Hash result fits the table, and p <= end - 8.
        write(self.hash, self.hash_at(p), p)
        block.add(0, len, @seqenc.Distance(rep2.reinterpret_as_uint()))
        let old = rep1
        rep1 = rep2
        rep2 = old
        p += len
        anchor = p
      }
    }
  }
  // anchor <= end <= the buffer's length.
  block.literals_from(self.history.data, anchor, end)
}

///|
/// Shared window, slack and block capacity, hash table and repeats.
pub fn Fast::memory_usage(self : Fast) -> Int32 {
  self.history.data.length() + 4 * self.hash.length() + 12
}

///|
/// Shared input storage; append only after reserving the next cutter block.
pub fn Fast::history(self : Fast) -> History {
  self.history
}

///|
/// Makes room for a whole cutter block, independently of input step sizes.
pub fn Fast::prepare(self : Fast, block_max : Int32) -> Unit {
  self.history.prepare(block_max) |> ignore
}
