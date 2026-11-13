// The row-based search of ZSTD_RowFindBestMatch (zstd 1.5.7,
// lib/compress/zstd_lazy.c), which the reference uses for greedy, lazy and
// lazy2 with a window over 2^14 bytes.
//
// The position table is split into rows of 2^rowLog slots. A row's slot 0
// holds no position: its tag byte is the row's head, the newest slot, and
// insertion walks backwards over slots 1..mask. Each slot's tag is the
// low eight bits of its position's hash, so one compare of the row's tags
// picks the candidates; they are examined newest first.
//
// Not carried over: the reference's eight-hash lookahead cache and its
// prefetches (MoonBit has no prefetch; the cached hashes equal the computed
// ones, so the matches are the same), and its hash salt (which spares
// clearing tables between frames; reset clears them here).

///|
/// After a gap of more than this many unindexed positions (a long match),
/// only the gap's first ROW_START_UPDATES and last ROW_END_UPDATES positions
/// are indexed, as ZSTD_row_update_internal does.
const ROW_SKIP_THRESHOLD : Int32 = 384

///|
const ROW_START_UPDATES : Int32 = 96

///|
const ROW_END_UPDATES : Int32 = 32

///|
/// Puts position `i`, whose hash is `h`, in the newest slot of its row.
fn Lazy::row_insert(self : Lazy, i : Int32, h : Int32) -> Unit {
  let mask = (1 << self.row_log) - 1
  // 0 <= h < 2^(hash_log - row_log + 8): the row's 2^row_log slots lie
  // in both tables of 2^hash_log entries.
  let base = h >> 8 << self.row_log
  let back = (read(self.tags, base).to_int() - 1) & mask
  let slot = if back == 0 { mask } else { back }
  write(self.tags, base, slot.to_byte())
  write(self.tags, base + slot, (h & 255).to_byte())
  write(self.hash, base + slot, i)
}

///|
/// Indexes the positions before p, then finds the longest match at p among
/// the row's candidates whose tag is p's, and indexes p. While skipping an
/// incompressible stretch, only searched positions are indexed.
fn Lazy::row_search(
  self : Lazy,
  p : Int32,
  end : Int32,
  skipping : Bool,
) -> Unit {
  if !skipping {
    let mut i = self.next_update
    if p - i > ROW_SKIP_THRESHOLD {
      for j in i..<(i + ROW_START_UPDATES) {
        self.row_insert(j, self.hash_at(j))
      }
      i = p - ROW_END_UPDATES
    }
    // Every i < p <= end - 8 (lazy lookahead may search end - 8):
    // hash_at's eight-byte reads at i and at p fit.
    while i < p {
      self.row_insert(i, self.hash_at(i))
      i += 1
    }
  }
  let h = self.hash_at(p)
  let mask = (1 << self.row_log) - 1
  let base = h >> 8 << self.row_log
  let tag = (h & 255).to_byte()
  let head = read(self.tags, base).to_int() & mask
  let low = (p - self.window).max(0)
  self.match_length = 3
  self.match_distance = 0
  self.row_candidates(p, end, base, tag, head, low)
  self.row_insert(p, h)
  self.next_update = p + 1
}

///|
/// Examines up to `attempts` candidates of the row at `base`, newest first:
/// slots head, head + 1, ... (mod the row size), skipping slot 0, whose tag
/// is the head. Positions only get older along the way, so the first one
/// below `low` (an empty slot is -1) ends the search.
#cfg(any(target="native", target="wasm"))
fn Lazy::row_candidates(
  self : Lazy,
  p : Int32,
  end : Int32,
  base : Int32,
  tag : Byte,
  head : Int32,
  low : Int32,
) -> Unit {
  let mask = (1 << self.row_log) - 1
  // An empty row's head is 0 (insertion never returns it there), and if
  // the newest position is out of the window, so is every other: no tag
  // comparison is needed. Sparse rows are common with a large table.
  // head <= mask: base + head is in the row.
  if head == 0 || read(self.hash, base + head) < low {
    return
  }
  let mut matches = @row_tags_fast.matches(
    self.tags,
    base,
    tag,
    head,
    self.row_log,
  )
  let mut attempts = self.attempts
  while matches != 0 && attempts > 0 {
    let slot = (head + matches.ctz()) & mask
    matches = matches & (matches - 1)
    if slot == 0 {
      continue
    }
    // base + slot is in the row.
    let q = read(self.hash, base + slot)
    // Indexed positions precede p; the check keeps reads below in range.
    if q < low || q >= p {
      break
    }
    attempts -= 1
    if self.row_consider(p, q, end) {
      break
    }
  }
}

///|
/// The same walk over the slots directly: on these targets, gathering the
/// tags into a mask costs as much as comparing them in the walk, and the
/// walk can stop at the first position out of the window.
#cfg(not(any(target="native", target="wasm")))
fn Lazy::row_candidates(
  self : Lazy,
  p : Int32,
  end : Int32,
  base : Int32,
  tag : Byte,
  head : Int32,
  low : Int32,
) -> Unit {
  let mask = (1 << self.row_log) - 1
  let mut attempts = self.attempts
  for k in 0..<=mask {
    if attempts == 0 {
      break
    }
    let slot = (head + k) & mask
    if slot == 0 {
      continue
    }
    // Positions only get older along the walk: once one is out of the
    // window, so is every candidate after it, whatever its tag. A sparse
    // row ends after its few entries instead of all its slots.
    let q = self.hash[base + slot]
    if q < low || q >= p {
      break
    }
    if self.tags[base + slot] != tag {
      continue
    }
    attempts -= 1
    if self.row_consider(p, q, end) {
      break
    }
  }
}

///|
/// Keeps candidate q if it beats the best so far. Returns whether the match
/// reaches `end`, which no later candidate can beat.
#inline
fn Lazy::row_consider(self : Lazy, p : Int32, q : Int32, end : Int32) -> Bool {
  let best = self.match_length
  // 0 <= q < p and p + best < end (search stops once a match reaches end).
  if may_beat(self.history.data, p, q, best) {
    let n = self.length(p, q, end)
    if n > best {
      self.match_length = n
      self.match_distance = p - q
      return p + n == end
    }
  }
  false
}
