// zstd 1.5.7 zstd_lazy.c's DUBT and zstd_opt.c's binary tree, adapted to
// contiguous retained History. BSD license; see zstd/NOTICE. -1 is empty,
// -2 is DUBT's unsorted mark, both within JS's small-integer range.

///|
/// Binary-tree match state for btlazy2 (-1), btopt (0) and btultra (2).
/// History holds the cutter's input; search never observes a step boundary.
pub struct Tree {
  priv hash : FixedArray[Int32]
  priv nodes : FixedArray[Int32]
  priv hash3 : FixedArray[Int32]
  priv hash_log : Int32
  priv hash3_log : Int32
  priv min_match : Int32
  priv attempts : Int32
  priv target : Int32
  priv opt_level : Int32
  priv ultra2 : Bool
  priv base_window : Int32
  priv mut window : Int32
  priv mut dict_end : Int32
  priv history : History
  priv mut bias : Int32
  priv mut next_update : Int32
  priv mut next3 : Int32
  priv mut match_length : Int32
  priv mut match_distance : Int32
  priv lengths : FixedArray[Int32]
  priv offsets : FixedArray[Int32]
  priv mut matches : Int32
  priv prices : Prices
  priv path : Optimal
  priv scratch : @seqenc.Repeats
}

///|
/// Allocates a hash head table, two child positions per chainLog-1 slot,
/// and, for optimal minMatch=3, a separate three-byte hash. DP and prices
/// are allocated only for optimal strategies. No long-distance matcher.
pub fn Tree::Tree(
  hash_log~ : Int32,
  chain_log~ : Int32,
  min_match~ : Int32,
  search_log~ : Int32,
  target_length~ : Int32,
  window_log~ : Int32,
  opt_level~ : Int32,
  ultra2~ : Bool = false,
) -> Tree {
  let hash = FixedArray::make(1 << hash_log, -1)
  let nodes = FixedArray::make(1 << chain_log, -1)
  let hash3_log = if opt_level >= 0 && min_match == 3 {
    window_log.min(17)
  } else {
    0
  }
  {
    hash,
    nodes,
    hash3: FixedArray::make(if hash3_log == 0 { 0 } else { 1 << hash3_log }, -1),
    hash_log,
    hash3_log,
    min_match: min_match.clamp(min=3, max=6),
    attempts: 1 << search_log,
    target: target_length.min(4095),
    opt_level,
    ultra2,
    base_window: 1 << window_log,
    window: 1 << window_log,
    dict_end: 0,
    history: History::new(1 << window_log, hash, nodes),
    bias: 0,
    next_update: 0,
    next3: 0,
    match_length: 0,
    match_distance: 0,
    lengths: FixedArray::make(if opt_level < 0 { 0 } else { 4099 }, 0),
    offsets: FixedArray::make(if opt_level < 0 { 0 } else { 4099 }, 0),
    matches: 0,
    prices: Prices::new(opt_level >= 0, opt_level),
    path: Optimal::new(opt_level >= 0),
    scratch: @seqenc.Repeats(),
  }
}

///|
/// Invalidates tree and entropy statistics so reset equals a fresh frame.
pub fn Tree::reset(self : Tree) -> Unit {
  self.history.reset()
  self.hash3.fill(-1)
  self.next_update = 0
  self.next3 = 0
  self.bias = 0
  self.window = self.base_window
  self.dict_end = 0
  self.history.set_window(self.window)
  self.prices.reset()
}

///|
/// Copies dictionary content into the same history as frame bytes; no
/// attached-dictionary tree or segmented comparisons are needed.
pub fn Tree::preload(self : Tree, dict : BytesView) -> Unit {
  guard dict.length() > 0 else { return }
  self.dict_end = dict.length()
  self.window = self.base_window + dict.length()
  self.history.preload(dict, self.window)
}

///|
/// Makes room for the next whole block, preserving ring indices and the
/// DUBT unsorted marks when stored positions move down.
pub fn Tree::prepare(self : Tree, block_max : Int32) -> Unit {
  if self.dict_end > 0 &&
    self.history.start + block_max > self.dict_end + self.base_window {
    self.dict_end = 0
    self.window = self.base_window
    self.history.set_window(self.window)
  }
  let cut = self.history.prepare(block_max)
  if cut > 0 {
    self.bias = (self.bias + cut) & (self.nodes.length() / 2 - 1)
    rebase_positions(self.hash3, cut)
    self.next_update = (self.next_update - cut).max(0)
    self.next3 = (self.next3 - cut).max(0)
    self.dict_end = (self.dict_end - cut).max(0)
  }
}

///|
/// Shared retained input and unfinished cutter block.
pub fn Tree::history(self : Tree) -> History {
  self.history
}

///|
/// Element payload of retained history, tree/hash tables and optimal scratch.
pub fn Tree::memory_usage(self : Tree) -> Int32 {
  self.history.capacity() +
  4 *
  (
    self.hash.length() +
    self.nodes.length() +
    self.hash3.length() +
    self.lengths.length() +
    self.offsets.length()
  ) +
  self.prices.memory_usage() +
  self.path.memory_usage() +
  12
}

///|
fn Tree::slot(self : Tree, p : Int32) -> Int32 {
  2 * ((p + self.bias) & (self.nodes.length() / 2 - 1))
}

///|
fn Tree::hash_at(self : Tree, p : Int32) -> Int32 {
  hash_bytes_tree(self.history.data, p, self.min_match.max(4), self.hash_log)
}

///|
#cfg(any(target="native", target="wasm"))
fn hash_bytes_tree(
  data : FixedArray[Byte],
  p : Int32,
  width : Int32,
  log : Int32,
) -> Int32 {
  if width == 4 {
    ((load32(data, p) * 2654435761U) >> (32 - log)).reinterpret_as_int()
  } else {
    (((load64(data, p) << (64 - 8 * width)) * hash_prime(width)) >> (64 - log)).to_int()
  }
}

///|
#cfg(not(any(target="native", target="wasm")))
fn hash_bytes_tree(
  data : FixedArray[Byte],
  p : Int32,
  width : Int32,
  log : Int32,
) -> Int32 {
  hash_bytes(data, p, width, log)
}

///|
fn Tree::length(self : Tree, p : Int32, q : Int32, end : Int32) -> Int32 {
  if q < 0 || q >= p || p - q > self.window {
    0
  } else {
    match_length(self.history.data, p, q, end)
  }
}

///|
fn Tree::record(self : Tree, length : Int32, off : Int32) -> Unit {
  self.lengths[self.matches] = length
  self.offsets[self.matches] = off
  self.matches += 1
}

///|
// One sorted insertion. Returns the next useful position, skipping the
// repetitive region ending eight bytes before a match's source end.
// Collect: 0 insertion only, 1 increasing optimal matches, 2 lazy best.
fn Tree::insert(
  self : Tree,
  p : Int32,
  end : Int32,
  candidate : Int32,
  compares : Int32,
  bt_low : Int32,
  low : Int32,
  collect : Int32,
) -> Int32 {
  let data = self.history.data
  let bt = self.nodes
  let mut small = self.slot(p)
  let mut large = small + 1
  let mut q = candidate
  let mut common_small = 0
  let mut common_large = 0
  let mut remaining = compares
  // ZSTD_DUBT_findBestMatch starts its candidate offBase at 999999999.
  // A zero raw distance would price the first match against highbit(3),
  // incorrectly rejecting short matches beyond one MiB.
  let mut best_off = 999999999
  let mut best = if collect == 1 {
    if self.matches == 0 {
      if self.min_match == 3 {
        2
      } else {
        3
      }
    } else {
      self.lengths[self.matches - 1]
    }
  } else if collect == 2 {
    0
  } else {
    8
  }
  let mut match_end = p + 9
  while remaining > 0 && q >= low && q >= 0 && q < p {
    let next = self.slot(q)
    let common = common_small.min(common_large)
    let length = common + match_length(data, p + common, q + common, end)
    if length > best {
      match_end = match_end.max(q + length)
      if collect == 1 {
        self.record(length, p - q + 3)
        best = length
      } else if collect == 2 {
        if 4 * (length - best) > 31 - (p - q + 1).clz() - (31 - best_off.clz()) {
          best = length
          best_off = p - q + 3
          self.match_length = length
          self.match_distance = p - q
        }
      } else {
        best = length
      }
    }
    if p + length == end || (collect == 1 && length > 4096) {
      break
    }
    if data[q + length] < data[p + length] {
      bt[small] = q
      common_small = length
      if q <= bt_low {
        small = -1
        break
      }
      small = next + 1
      q = bt[small]
    } else {
      bt[large] = q
      common_large = length
      if q <= bt_low {
        large = -1
        break
      }
      large = next
      q = bt[large]
    }
    remaining -= 1
  }
  if small >= 0 {
    bt[small] = -1
  }
  if large >= 0 {
    bt[large] = -1
  }
  match_end - 8
}

///|
// ZSTD_updateDUBT, followed by the reversed unsorted chain and batch sort
// of ZSTD_DUBT_findBestMatch. Marks must never be treated as positions.
fn Tree::search(self : Tree, p : Int32, end : Int32, _skipping : Bool) -> Unit {
  self.match_length = 0
  self.match_distance = 0
  guard p >= self.next_update else { return }
  let mask = self.nodes.length() / 2 - 1
  let low = (p - self.window).max(0)
  for i in self.next_update.max(low)..<p {
    let h = self.hash_at(i)
    let slot = self.slot(i)
    self.nodes[slot] = self.hash[h]
    self.nodes[slot + 1] = -2
    self.hash[h] = i
  }
  let h = self.hash_at(p)
  let limit = (p - mask).max(low)
  let mut q = self.hash[h]
  let mut previous = -1
  let mut budget = self.attempts
  while q >= limit && self.nodes[self.slot(q) + 1] == -2 && budget > 1 {
    let slot = self.slot(q)
    self.nodes[slot + 1] = previous
    previous = q
    q = self.nodes[slot]
    budget -= 1
  }
  if q >= limit && self.nodes[self.slot(q) + 1] == -2 {
    self.nodes[self.slot(q)] = -1
    self.nodes[self.slot(q) + 1] = -1
  }
  q = previous
  while q >= 0 {
    let slot = self.slot(q)
    let next = self.nodes[slot + 1]
    self.insert(
      q,
      end,
      self.nodes[slot],
      budget,
      limit,
      (q - self.window).max(0),
      0,
    )
    |> ignore
    q = next
    budget += 1
  }
  q = self.hash[h]
  self.hash[h] = p
  self.next_update = self.insert(p, end, q, self.attempts, p - mask, low, 2)
}

///|
fn Tree::all_matches(
  self : Tree,
  p : Int32,
  end : Int32,
  reps : @seqenc.Repeats,
  ll : Int32,
) -> Unit {
  self.matches = 0
  guard p >= self.next_update else { return }
  let low = (p - self.window).max(0)
  let mask = self.nodes.length() / 2 - 1
  // ZSTD_updateTree_internal: skipped positions are sorted without emitting
  // matches, and repetitive source regions need not all be inserted.
  while self.next_update < p {
    let at = self.next_update.max(low)
    // Both next_update and low are below p (window is positive).
    let h = self.hash_at(at)
    let q = self.hash[h]
    self.hash[h] = at
    self.next_update = self.insert(at, end, q, self.attempts, at - mask, low, 0)
  }
  // Repcodes first, including the zero-literal shift and rep1-1. Use the
  // same resolver as the writer, then filter impossible/expired distances.
  let min_match = if self.min_match == 3 { 3 } else { 4 }
  let mut best = min_match - 1
  for code in 1..<=3 {
    self.scratch.copy_from(reps)
    let @seqenc.Distance(d) = self.scratch.resolve(
      @seqenc.OffsetValue(code.reinterpret_as_uint()),
      ll,
    )
    let q = p - d.reinterpret_as_int()
    let length = if d > 0 && d <= p.reinterpret_as_uint() && q >= low {
      self.length(p, q, end)
    } else {
      0
    }
    if length > best {
      self.record(length, code)
      best = length
      if length > self.target || p + length == end {
        return
      }
    }
  }
  if self.hash3.length() > 0 {
    let mut found = -1
    for at in self.next3.max(low)..<=p {
      let data = self.history.data
      let word = data[at].to_uint() |
        (data[at + 1].to_uint() << 8) |
        (data[at + 2].to_uint() << 16)
      let h = (((word << 8) * 506832829U) >> (32 - self.hash3_log)).reinterpret_as_int()
      found = self.hash3[h]
      self.hash3[h] = at
    }
    self.next3 = p + 1
    if best < 3 && found >= low && found < p && p - found < 1 << 18 {
      let length = self.length(p, found, end)
      if length >= 3 {
        self.record(length, p - found + 3)
        if length > self.target || p + length == end {
          self.next_update = p + 1
          return
        }
      }
    }
  }
  let h = self.hash_at(p)
  let q = self.hash[h]
  self.hash[h] = p
  self.next_update = self.insert(p, end, q, self.attempts, p - mask, low, 1)
}

///|
/// Parses a block already appended by the cutter; a btultra2 first pass
/// primes prices only, then discards tree positions and speculative repeats.
pub fn Tree::find_buffered(
  self : Tree,
  n : Int32,
  repeats : @seqenc.Repeats,
  block : @seqenc.Block,
) -> Unit {
  if self.opt_level < 0 {
    self.lazy_block(n, repeats, block)
    return
  }
  if self.ultra2 && self.prices.ll_sum == 0 && self.history.start == 0 && n > 8 {
    self.optimal_block(n, repeats, block)
    self.hash.fill(-1)
    self.nodes.fill(-1)
    self.hash3.fill(-1)
    self.next_update = 0
    self.next3 = 0
  }
  self.optimal_block(n, repeats, block)
}
