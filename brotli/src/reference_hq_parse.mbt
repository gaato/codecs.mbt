// Port of google/brotli v1.2.1 c/enc/backward_references_hq.c.
// Copyright 2013 Google Inc.; MIT, see LICENSE-encoder.

///|
fn Encoder::hq_find(
  self : Encoder,
  tree : HqTree,
  quality : Int32,
  data : FixedArray[Byte],
  start : Int32,
  absolute : UInt32,
  pos : Int32,
  length : Int32,
) -> Unit {
  let current = absolute + pos.reinterpret_as_uint()
  let reach = current.to_uint64().min(self.max_distance.to_uint64()).to_int()
  tree.find(
    data,
    start + pos,
    current,
    length - pos,
    reach,
    self.ref_dictionary_reach(reach),
    quality,
  )
  if self.dictionary is Some(dict) && length - pos >= 4 {
    let index = dict.search_index()
    let mut candidate = index.head[@lz77.hash4(data, start + pos, index.bits)] -
      1
    let mut best = 3
    let mut found = 0
    let mut attempts = 128
    while candidate >= 0 && attempts > 0 && found < 64 {
      let distance = reach.to_int64() +
        (index.bytes.length() - candidate).to_int64()
      if distance > MAX_CODED_DISTANCE.to_int64() {
        break
      }
      let limit = (length - pos).min(index.bytes.length() - candidate)
      let mut n = 0
      while n < limit && index.bytes[candidate + n] == data[start + pos + n] {
        n += 1
      }
      if n > best {
        best = n
        let at = tree.count
        tree.add(distance.to_int(), n)
        // Merge the raw-dictionary candidates with H10's length-ordered list.
        let mut i = at
        while i > 0 {
          let l = tree.matches[2 * i + 1] >> 5
          let p = tree.matches[2 * i - 1] >> 5
          if p < l || (p == l && tree.matches[2 * i - 2] < tree.matches[2 * i]) {
            break
          }
          for k in 0..<2 {
            let v = tree.matches[2 * i + k]
            tree.matches[2 * i + k] = tree.matches[2 * i - 2 + k]
            tree.matches[2 * i - 2 + k] = v
          }
          i -= 1
        }
        found += 1
      }
      candidate = index.chain[candidate] - 1
      attempts -= 1
    }
  }
}

///|
fn Encoder::hq_parse(
  self : Encoder,
  tree : HqTree,
  quality : Int32,
  start : Int32,
  end : Int32,
  absolute : UInt32,
) -> Unit {
  let length = end - start
  let initial = FixedArray::makei(4, i => self.ref_distances[i])
  let dp = HqDp::new(length, quality)
  let memory = tree.peak.map(p => HqMemory::new(self, p, true))
  let mark = hq_memory_mark(memory)
  defer hq_memory_restore(memory, mark)
  hq_memory_add(memory, dp.memory_usage() + 4L * initial.length().to_int64())
  let store_end = if length >= 128 { length - 127 } else { 0 }
  let gap = match self.dictionary {
    Some(d) => d.length()
    None => 0
  }
  if quality == 10 {
    dp.clear()
    dp.model.initial(self.data, start, length, memory?)
    if memory is Some(m) {
      m.peak.passes += 1
    }
    let mut i = 0
    while i + 3 < length {
      self.hq_find(tree, quality, self.data, start, absolute, i, length)
      if tree.count > 0 && tree.matches[2 * tree.count - 1] >> 5 > 150U {
        tree.matches[0] = tree.matches[2 * tree.count - 2]
        tree.matches[1] = tree.matches[2 * tree.count - 1]
        tree.count = 1
      }
      let mut skip = dp.update(
        self,
        self.data,
        start,
        absolute,
        i,
        length,
        initial,
        tree.matches[:2 * tree.count],
      )
      if skip < 16384 {
        skip = 0
      }
      if tree.count == 1 && tree.matches[1] >> 5 > 150U {
        skip = skip.max((tree.matches[1] >> 5).reinterpret_as_int())
      }
      if skip > 1 {
        tree.store_range(
          self.data,
          start,
          absolute,
          i + 1,
          (i + skip).min(store_end),
        )
        let stop = i + skip
        i += 1
        while i < stop && i + 3 < length {
          dp.evaluate(i, absolute, self.max_distance, gap, initial)
          i += 1
        }
      } else {
        i += 1
      }
    }
    dp.backtrack(self, absolute, length)
  } else {
    let counts = FixedArray::make(length, 0)
    let archive : Array[UInt32] = Array(capacity=8 * length)
    hq_memory_add(
      memory,
      4L * (counts.length() + archive.capacity()).to_int64(),
    )
    if memory is Some(m) {
      m.peak.archive_capacity = m.peak.archive_capacity.max(archive.capacity())
    }
    let mut i = 0
    while i + 3 < length {
      let need = archive.length() +
        (if self.dictionary is Some(_) { 512 } else { 256 })
      let previous_capacity = archive.capacity()
      let mut capacity = previous_capacity.max(1)
      while capacity < need {
        capacity *= 2
      }
      archive.reserve_capacity(capacity)
      if archive.capacity() != previous_capacity {
        hq_memory_add(
          memory,
          4L * (archive.capacity() - previous_capacity).to_int64(),
        )
        if memory is Some(m) {
          m.peak.archive_grows += 1
          m.peak.archive_capacity = m.peak.archive_capacity.max(
            archive.capacity(),
          )
        }
      }
      self.hq_find(tree, quality, self.data, start, absolute, i, length)
      let mut size = 0
      if tree.count > 0 {
        size = (tree.matches[2 * tree.count - 1] >> 5).reinterpret_as_int()
      }
      if size > 325 {
        archive.push(tree.matches[2 * tree.count - 2])
        archive.push(tree.matches[2 * tree.count - 1])
        counts[i] = 1
        tree.store_range(
          self.data,
          start,
          absolute,
          i + 1,
          (i + size).min(store_end),
        )
        i += size
      } else {
        counts[i] = tree.count
        for j in 0..<(2 * tree.count) {
          archive.push(tree.matches[j])
        }
        i += 1
      }
    }
    let commands = self.ref_commands.unwrap()
    let original_count = commands.length()
    let original_literals = self.ref_literals
    let original_insert = self.ref_insert
    for pass in 0..<2 {
      dp.clear()
      if pass == 0 {
        dp.model.initial(self.data, start, length, memory?)
      } else {
        dp.model.from_commands(
          self.data,
          start,
          length,
          commands,
          original_count,
          original_insert,
          memory?,
        )
      }
      commands.truncate(original_count)
      self.ref_literals = original_literals
      self.ref_insert = original_insert
      for j in 0..<4 {
        self.ref_distances[j] = initial[j]
      }
      let mut at = 0
      let mut i = 0
      while i + 3 < length {
        let count = counts[i]
        let mut skip = dp.update(
          self,
          self.data,
          start,
          absolute,
          i,
          length,
          initial,
          archive[at:at + 2 * count],
        )
        if skip < 16384 {
          skip = 0
        }
        at += 2 * count
        if count == 1 && archive[at - 1] >> 5 > 325U {
          skip = skip.max((archive[at - 1] >> 5).reinterpret_as_int())
        }
        if skip > 1 {
          let stop = i + skip
          i += 1
          while i < stop && i + 3 < length {
            dp.evaluate(i, absolute, self.max_distance, gap, initial)
            at += 2 * counts[i]
            i += 1
          }
        } else {
          i += 1
        }
      }
      dp.backtrack(self, absolute, length)
      hq_memory_add(memory, 0L)
      if memory is Some(m) {
        m.peak.passes += 1
      }
    }
  }
}
