// Forward stretches (a match followed by literals), zstd_opt.c's optimal
// parser. Flat arrays avoid a heap object per position on JS and native.

///|
// All real prices are below 10^9. One less than C's 2^30 infinity keeps
// this sentinel within the signed 31-bit JS small-integer range as well.
const OPT_MAX_PRICE : Int32 = 0x3fffffff

///|
priv struct Optimal {
  price : FixedArray[Int32]
  ml : FixedArray[Int32]
  ll : FixedArray[Int32]
  off : FixedArray[Int32]
  r1 : FixedArray[Int32]
  r2 : FixedArray[Int32]
  r3 : FixedArray[Int32]
  seq_ll : FixedArray[Int32]
  seq_ml : FixedArray[Int32]
  seq_off : FixedArray[Int32]
  repeats : @seqenc.Repeats
}

///|
fn Optimal::new(enabled : Bool) -> Optimal {
  let n = if enabled { 4099 } else { 0 }
  {
    price: FixedArray::make(n, 0),
    ml: FixedArray::make(n, 0),
    ll: FixedArray::make(n, 0),
    off: FixedArray::make(n, 0),
    r1: FixedArray::make(n, 0),
    r2: FixedArray::make(n, 0),
    r3: FixedArray::make(n, 0),
    seq_ll: FixedArray::make(n, 0),
    seq_ml: FixedArray::make(n, 0),
    seq_off: FixedArray::make(n, 0),
    repeats: @seqenc.Repeats(),
  }
}

///|
fn Optimal::memory_usage(self : Optimal) -> Int32 {
  40 * self.price.length() + 12
}

///|
fn Optimal::copy(self : Optimal, to : Int32, from : Int32) -> Unit {
  self.price[to] = self.price[from]
  self.ml[to] = self.ml[from]
  self.ll[to] = self.ll[from]
  self.off[to] = self.off[from]
  self.r1[to] = self.r1[from]
  self.r2[to] = self.r2[from]
  self.r3[to] = self.r3[from]
}

///|
fn Optimal::load_reps(
  self : Optimal,
  at : Int32,
  reps : @seqenc.Repeats,
) -> Unit {
  reps.set(
    self.r1[at].reinterpret_as_uint(),
    self.r2[at].reinterpret_as_uint(),
    self.r3[at].reinterpret_as_uint(),
  )
}

///|
fn Optimal::save_reps(
  self : Optimal,
  at : Int32,
  reps : @seqenc.Repeats,
) -> Unit {
  let @seqenc.Distance(r1) = reps.get(0)
  let @seqenc.Distance(r2) = reps.get(1)
  let @seqenc.Distance(r3) = reps.get(2)
  self.r1[at] = r1.reinterpret_as_int()
  self.r2[at] = r2.reinterpret_as_int()
  self.r3[at] = r3.reinterpret_as_int()
}

///|
// Block.add encodes a raw Distance using its canonical first matching
// repcode. Price and propagate exactly that state, including duplicate
// recent distances, instead of assuming a raw offset always shifts reps.
fn Tree::canonical(self : Tree, from : Int32, off : Int32) -> Int32 {
  let opt = self.path
  opt.load_reps(from, self.scratch)
  let distance = self.scratch.resolve(
    @seqenc.OffsetValue(off.reinterpret_as_uint()),
    opt.ll[from],
  )
  opt.load_reps(from, self.scratch)
  let @seqenc.OffsetValue(actual) = self.scratch.encode(distance, opt.ll[from])
  actual.reinterpret_as_int()
}

///|
fn Tree::optimal_block(
  self : Tree,
  n : Int32,
  repeats : @seqenc.Repeats,
  block : @seqenc.Block,
) -> Unit {
  let start = self.history.start
  let end = start + n
  let data = self.history.data
  let opt = self.path
  let prices = self.prices
  let min_match = if self.min_match == 3 { 3 } else { 4 }
  block.reset(repeats, n)
  prices.rescale(data, start, end)
  self.next_update = self.next_update.max((start - self.window).max(0))
  let mut anchor = start
  let mut ip = start.max(1)
  while ip < end - 8 {
    let litlen = ip - anchor
    self.all_matches(ip, end, block.repeats, litlen)
    if self.matches == 0 {
      ip += 1
      continue
    }
    opt.ml[0] = 0
    opt.ll[0] = litlen
    opt.price[0] = prices.literal_length(litlen)
    opt.save_reps(0, block.repeats)
    let mut last = self.lengths[self.matches - 1]
    let mut terminal_ml = last
    let mut terminal_off = self.canonical(0, self.offsets[self.matches - 1])
    let mut terminal_ll = 0
    let mut terminal_start = 0
    if last <= self.target {
      for p in 1..<min_match {
        opt.price[p] = OPT_MAX_PRICE
        opt.ml[p] = 0
        opt.ll[p] = litlen + p
      }
      let mut pos = min_match
      for m in 0..<self.matches {
        let off = self.canonical(0, self.offsets[m])
        while pos <= self.lengths[m] {
          opt.price[pos] = opt.price[0] +
            prices.match_price(off, pos) +
            prices.literal_length(0)
          opt.ml[pos] = pos
          opt.ll[pos] = 0
          opt.off[pos] = off
          pos += 1
        }
      }
      opt.price[last + 1] = OPT_MAX_PRICE
      let mut cur = 1
      let mut forced = false
      while cur <= last {
        let ll = opt.ll[cur - 1] + 1
        let price = opt.price[cur - 1] +
          prices.literal(data[ip + cur - 1]) +
          prices.literal_length(ll) -
          prices.literal_length(ll - 1)
        if price <= opt.price[cur] {
          let old_price = opt.price[cur]
          let old_ml = opt.ml[cur]
          let old_off = opt.off[cur]
          let old_ll = opt.ll[cur]
          opt.copy(cur, cur - 1)
          opt.ll[cur] = ll
          opt.price[cur] = price
          if self.opt_level == 2 &&
            old_ll == 0 &&
            prices.literal_length(1) < prices.literal_length(0) &&
            ip + cur < end {
            let next_price = old_price +
              prices.literal(data[ip + cur]) +
              prices.literal_length(1) -
              prices.literal_length(0)
            let more = price +
              prices.literal(data[ip + cur]) +
              prices.literal_length(ll + 1) -
              prices.literal_length(ll)
            if next_price < more && next_price < opt.price[cur + 1] {
              let prev = cur - old_ml
              self.canonical(prev, old_off) |> ignore
              opt.save_reps(cur + 1, self.scratch)
              opt.ml[cur + 1] = old_ml
              opt.off[cur + 1] = old_off
              opt.ll[cur + 1] = 1
              opt.price[cur + 1] = next_price
              last = last.max(cur + 1)
            }
          }
        }
        if opt.ll[cur] == 0 {
          self.canonical(cur - opt.ml[cur], opt.off[cur]) |> ignore
          opt.save_reps(cur, self.scratch)
        }
        if ip + cur > end - 8 {
          cur += 1
          continue
        }
        if cur == last {
          break
        }
        if self.opt_level == 0 && opt.price[cur + 1] <= opt.price[cur] + 128 {
          cur += 1
          continue
        }
        // all_matches uses scratch internally: pass an independent set of
        // scalar-backed repeats so its trials cannot overwrite its input.
        self.all_at_path(cur, ip + cur, end)
        if self.matches == 0 {
          cur += 1
          continue
        }
        let longest = self.lengths[self.matches - 1]
        if longest > self.target ||
          cur + longest >= 4096 ||
          ip + cur + longest >= end {
          terminal_ml = longest
          terminal_off = self.canonical(cur, self.offsets[self.matches - 1])
          terminal_ll = 0
          terminal_start = cur
          last = cur + longest
          forced = true
          break
        }
        let base = opt.price[cur] + prices.literal_length(0)
        for m in 0..<self.matches {
          let off = self.canonical(cur, self.offsets[m])
          let first = if m == 0 { min_match } else { self.lengths[m - 1] + 1 }
          for ml = self.lengths[m]; ml >= first; ml = ml - 1 {
            let at = cur + ml
            let price = base + prices.match_price(off, ml)
            if at > last || price < opt.price[at] {
              while last < at {
                last += 1
                opt.price[last] = OPT_MAX_PRICE
                opt.ll[last] = 1
              }
              opt.ml[at] = ml
              opt.off[at] = off
              opt.ll[at] = 0
              opt.price[at] = price
            } else if self.opt_level == 0 {
              break
            }
          }
        }
        opt.price[last + 1] = OPT_MAX_PRICE
        cur += 1
      }
      if !forced {
        terminal_ml = opt.ml[last]
        terminal_off = opt.off[last]
        terminal_ll = opt.ll[last]
        terminal_start = last - terminal_ml - terminal_ll
      }
    }
    if terminal_ml == 0 {
      ip += last
      continue
    }
    // Backtrack stretches into a separate bounded sequence stack. This
    // avoids aliasing the forward table while keeping reference decisions.
    let mut count = 0
    let mut at = terminal_start
    let mut ml = terminal_ml
    let mut off = terminal_off
    for ;; {
      opt.seq_ll[count] = opt.ll[at]
      opt.seq_ml[count] = ml
      opt.seq_off[count] = off
      count += 1
      ml = opt.ml[at]
      off = opt.off[at]
      if ml == 0 {
        break
      }
      at -= opt.ll[at] + ml
    }
    for i = count - 1; i >= 0; i = i - 1 {
      let ll = opt.seq_ll[i]
      let ml = opt.seq_ml[i]
      self.scratch.copy_from(block.repeats)
      let distance = self.scratch.resolve(
        @seqenc.OffsetValue(opt.seq_off[i].reinterpret_as_uint()),
        ll,
      )
      block.literals_from(data, anchor, anchor + ll)
      block.add(ll, ml, distance)
      let @seqenc.OffsetValue(actual) = block.offsets[block.count - 1]
      prices.update(data, anchor, ll, actual.reinterpret_as_int(), ml)
      anchor += ll + ml
    }
    ip = anchor + terminal_ll
    prices.set_bases()
  }
  block.literals_from(data, anchor, end)
}

///|
fn Tree::all_at_path(self : Tree, cur : Int32, p : Int32, end : Int32) -> Unit {
  self.path.load_reps(cur, self.path.repeats)
  self.all_matches(p, end, self.path.repeats, self.path.ll[cur])
}
