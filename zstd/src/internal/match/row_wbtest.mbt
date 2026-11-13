///|
/// A plain model of the row finder: each row a list of its last
/// 2^row_log - 1 positions and tags, newest first, filled on the same
/// schedule as `row_search`. Returns the match the search must find.
priv struct RowModel {
  rows : Array[Array[(Int32, Int32)]]
  capacity : Int32
  mut next : Int32
}

///|
fn RowModel::insert(self : RowModel, finder : Lazy, i : Int32) -> Unit {
  let h = finder.hash_at(i)
  let row = self.rows[h >> 8]
  row.insert(0, (i, h & 255))
  if row.length() > self.capacity {
    row.pop() |> ignore
  }
}

///|
fn RowModel::search(
  self : RowModel,
  finder : Lazy,
  data : FixedArray[Byte],
  p : Int32,
  end : Int32,
  skipping : Bool,
) -> (Int32, Int32) {
  if !skipping {
    let mut i = self.next
    if p - i > 384 {
      for j in i..<(i + 96) {
        self.insert(finder, j)
      }
      i = p - 32
    }
    for j in i..<p {
      self.insert(finder, j)
    }
  }
  let h = finder.hash_at(p)
  let low = (p - finder.window).max(0)
  let mut attempts = finder.attempts
  let mut best = 3
  let mut distance = 0
  for candidate in self.rows[h >> 8] {
    let (q, tag) = candidate
    if tag != (h & 255) {
      continue
    }
    if q < low || attempts == 0 {
      break
    }
    attempts -= 1
    let mut n = 0
    while p + n < end && data[p + n] == data[q + n] {
      n += 1
    }
    if n > best {
      best = n
      distance = p - q
      if p + n == end {
        break
      }
    }
  }
  self.insert(finder, p)
  self.next = p + 1
  (best, distance)
}

///|
test "row search finds the model's match, newest candidates first" {
  let mut seed = 99991U
  fn next() {
    seed = seed * 1664525 + 1013904223
    seed >> 8
  }

  for search_log in [3, 4, 5, 6, 7] {
    for min_match in [4, 5, 6] {
      let finder = Lazy(
        hash_log=10,
        chain_log=10,
        min_match~,
        search_log~,
        depth=0,
        // 8 KiB: older candidates fall out of the window. The history holds
        // three windows, the whole input.
        window_log=13,
        row_finder=true,
      )
      let row_log = search_log.clamp(min=4, max=6)
      assert_eq(finder.row_log, row_log)
      assert_eq(finder.attempts, 1 << search_log.min(row_log))
      assert_eq(finder.chain.length(), 0)
      let model = RowModel::{
        rows: Array::makei(1 << (10 - row_log), _ => []),
        capacity: (1 << row_log) - 1,
        next: 0,
      }
      // Few distinct words: rows fill and wrap, tags collide, and matches
      // run long. Some stretches are random, others one repeated byte.
      let n = 20000
      let data = FixedArray::makei(n, i => {
        let kind = i / 2500 % 4
        if kind == 1 {
          next().to_byte()
        } else if kind == 3 && i % 2500 > 2000 {
          b'z'
        } else {
          b"abcabdabeaxyz"[(next() % 13).reinterpret_as_int()]
        }
      })
      finder.prepare(n)
      finder.history.append_fixed(data, n)
      let mut p = 1
      let mut found = 0
      while p < n - 8 {
        let skipping = next() % 9 == 0
        finder.search(p, n, skipping)
        let (len, distance) = model.search(finder, data, p, n, skipping)
        assert_eq((finder.match_length, finder.match_distance), (len, distance))
        if len > 3 {
          found += 1
        }
        // Mostly small steps, sometimes a gap past the 384 threshold.
        p += if next() % 50 == 0 {
          300 + (next() % 400).reinterpret_as_int()
        } else {
          1 + (next() % 4).reinterpret_as_int()
        }
      }
      // At least 43 for every setting; six-byte hashes find the fewest.
      assert_true(found > 30)
    }
  }
}

///|
test "a reset row finder fills its rows as a new one does" {
  let data = FixedArray::makei(5000, i => (i * i % 97 % 11).to_byte())
  let fresh = Lazy(
    hash_log=9,
    chain_log=9,
    min_match=4,
    search_log=5,
    depth=2,
    window_log=12,
    row_finder=true,
  )
  let reused = Lazy(
    hash_log=9,
    chain_log=9,
    min_match=4,
    search_log=5,
    depth=2,
    window_log=12,
    row_finder=true,
  )
  let other = FixedArray::makei(5000, i => (i % 13).to_byte())
  let block = @seqenc.Block()
  reused.find(other, other.length(), @seqenc.Repeats(), block)
  reused.reset()
  assert_true(reused.tags.iter().all(t => t == b'\x00'))
  let a = @seqenc.Block()
  let b = @seqenc.Block()
  fresh.find(data, data.length(), @seqenc.Repeats(), a)
  reused.find(data, data.length(), @seqenc.Repeats(), b)
  assert_eq(a.count, b.count)
  for i in 0..<a.count {
    assert_eq(a.ll[i], b.ll[i])
    assert_eq(a.ml[i], b.ml[i])
    let @seqenc.OffsetValue(x) = a.offsets[i]
    let @seqenc.OffsetValue(y) = b.offsets[i]
    assert_eq(x, y)
  }
}
