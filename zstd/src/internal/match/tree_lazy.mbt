// The lazy2 parser shared in algorithm with lazy.mbt, using DUBT search.

///|
fn Tree::lazy_block(
  self : Tree,
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
      if p < end - 8 {
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
