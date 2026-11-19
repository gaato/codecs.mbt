// google/brotli v1.2.1 hash_longest_match_quickly_inc.h (H2/H3).
// Copyright 2010, 2016 Google Inc.; MIT, see LICENSE-encoder.

///|
priv struct QuickHasher {
  sweep : Int32
  buckets : FixedArray[UInt32]
  words : FixedArray[UInt16]
  lengths : FixedArray[Byte]
  mut prepared : Bool
  mut lookups : Int64
  mut matches : Int64
}

///|
fn QuickHasher::new(quality : Int32) -> QuickHasher {
  {
    sweep: if quality == 2 {
      1
    } else {
      2
    },
    buckets: FixedArray::make(65536, 0U),
    words: if quality == 2 {
      ref_dict_words()
    } else {
      []
    },
    lengths: if quality == 2 {
      ref_dict_lengths()
    } else {
      []
    },
    prepared: true,
    lookups: 0L,
    matches: 0L,
  }
}

///|
fn QuickHasher::hash(data : FixedArray[Byte], pos : Int32) -> Int32 {
  let word = ref_load4(data, pos).to_uint64() |
    (data[pos + 4].to_uint64() << 32)
  (((word << 24) * 0x1fe35a7bd3579bd3UL) >> 48).to_int()
}

///|
fn QuickHasher::prepare(self : QuickHasher) -> Unit {
  if !self.prepared {
    self.buckets.fill(0U)
    self.prepared = true
  }
}

///|
fn QuickHasher::store(
  self : QuickHasher,
  data : FixedArray[Byte],
  pos : Int32,
  absolute : UInt32,
) -> Unit {
  let key = QuickHasher::hash(data, pos)
  let off = (absolute & ((self.sweep - 1) << 3).reinterpret_as_uint()).reinterpret_as_int()
  self.buckets[(key + off) & 65535] = absolute
}

///|
fn QuickHasher::dictionary(
  self : QuickHasher,
  data : FixedArray[Byte],
  pos : Int32,
  limit : Int32,
  reach : Int32,
  result : RefMatch,
) -> Unit {
  if self.matches < self.lookups >> 7 {
    return
  }
  let key = ((ref_load4(data, pos) * 0x1e35a7bdU) >> 18).reinterpret_as_int() <<
    1
  self.lookups += 1L
  let length = self.lengths[key].to_int()
  if length == 0 || length > limit {
    return
  }
  let word = self.words[key].to_int()
  let offset = dictionary_offsets[length] + length * word
  let mut n = 0
  while n < length && data[pos + n] == dictionary[offset + n] {
    n += 1
  }
  if n == 0 || n + 10 <= length {
    return
  }
  let cut = length - n
  let transform = (cut << 2) +
    ((0x071b520ada2d3200UL >> (cut * 6)) & 63UL).to_int()
  let distance = reach + 1 + word + (transform << dictionary_size_bits[length])
  if distance > MAX_CODED_DISTANCE {
    return
  }
  let score = ref_score(n, distance)
  if score >= result.score {
    result.length = n
    result.delta = length - n
    result.distance = distance
    result.score = score
    self.matches += 1L
  }
}

///|
fn QuickHasher::find(
  self : QuickHasher,
  data : FixedArray[Byte],
  pos : Int32,
  absolute : UInt32,
  end : Int32,
  reach : Int32,
  dictionary_reach : Int32,
  cache : FixedArray[Int32],
  best_in : Int32,
) -> RefMatch {
  // quick_parse bounds end by data_len and retains the matching window.
  // Cached and bucket distances are checked before counting a match.
  let result = RefMatch::new()
  result.length = best_in
  let key = QuickHasher::hash(data, pos)
  let mut best = best_in
  let mut compare = data[pos + best]
  let distance = cache[0]
  if distance > 0 &&
    distance.to_uint64() <= absolute.to_uint64() &&
    compare == data[pos - distance + best] {
    let n = ref_match_length(data, pos - distance, pos, end - pos)
    if n >= 4 {
      let score = 1920 + 135 * n + 15
      if score > result.score {
        result.length = n
        result.distance = distance
        result.score = score
        if self.sweep == 1 {
          self.buckets[key] = absolute
          return result
        }
        best = n
        compare = data[pos + n]
      }
    }
  }
  if self.sweep == 1 {
    let previous = self.buckets[key]
    self.buckets[key] = absolute
    let backward = (absolute - previous).to_uint64()
    if backward == 0UL || backward > reach.to_uint64() {
      return result
    }
    let prev = pos - backward.to_int()
    if compare != data[prev + best_in] {
      return result
    }
    let n = ref_match_length(data, prev, pos, end - pos)
    if n >= 4 {
      let score = ref_score(n, backward.to_int())
      if score > result.score {
        result.length = n
        result.distance = backward.to_int()
        result.score = score
        return result
      }
    }
    if result.score == 2020 {
      self.dictionary(data, pos, end - pos, dictionary_reach, result)
    }
  } else {
    for i in 0..<self.sweep {
      let previous = self.buckets[(key + 8 * i) & 65535]
      let backward = (absolute - previous).to_uint64()
      if backward == 0UL || backward > reach.to_uint64() {
        continue
      }
      let prev = pos - backward.to_int()
      if compare != data[prev + best] {
        continue
      }
      let n = ref_match_length(data, prev, pos, end - pos)
      if n >= 4 {
        let score = ref_score(n, backward.to_int())
        if score > result.score {
          best = n
          compare = data[pos + n]
          result.length = n
          result.distance = backward.to_int()
          result.score = score
        }
      }
    }
    self.buckets[(key + (absolute & 8U).reinterpret_as_int()) & 65535] = absolute
  }
  result
}

///|
fn Encoder::quick_find(
  self : Encoder,
  hasher : QuickHasher,
  pos : Int32,
  end : Int32,
  best : Int32,
) -> RefMatch {
  let total = self.ref_offset + pos.to_int64()
  let reach = total.min(self.max_distance.to_int64()).to_int()
  hasher.find(
    self.data,
    pos,
    ref_wrap(total),
    end,
    reach,
    self.ref_dictionary_reach(reach),
    self.ref_distances,
    best,
  )
}

///|
fn Encoder::quick_parse(
  self : Encoder,
  hasher : QuickHasher,
  start : Int32,
  end : Int32,
) -> Unit {
  let commands = self.ref_commands.unwrap()
  let store_end = if end - start >= 8 { end - 7 } else { start }
  let mut random_at = start + 64
  let mut pos = start
  let mut insert = self.ref_insert
  let cache = self.ref_distances
  while pos + 8 < end {
    let mut found = self.quick_find(hasher, pos, end, 0)
    if found.score > 2020 {
      let mut delayed = 0
      for ;; {
        let next = self.quick_find(
          hasher,
          pos + 1,
          end,
          (found.length - 1).min(end - pos - 1),
        )
        if next.score >= found.score + 175 {
          pos += 1
          insert += 1
          found = next
          delayed += 1
          if delayed < 4 && pos + 8 < end {
            continue
          }
        }
        break
      }
      random_at = pos + 2 * found.length + 64
      let reach = (self.ref_offset + pos.to_int64())
        .min(self.max_distance.to_int64())
        .to_int()
      let dictionary_reach = self.ref_dictionary_reach(reach)
      let dc = ref_distance_code(found.distance, dictionary_reach, cache)
      if found.distance <= dictionary_reach && dc > 0 {
        for i = 3; i > 0; i = i - 1 {
          cache[i] = cache[i - 1]
        }
        cache[0] = found.distance
      }
      commands.push(RefCommand::new(insert, found.length, found.delta, dc))
      self.ref_literals += insert
      insert = 0
      let range_end = (pos + found.length).min(store_end)
      let mut from = pos + 2
      if found.distance < found.length >> 2 {
        from = range_end.min(
          from.max(pos + found.length - (found.distance << 2)),
        )
      }
      for p in from..<range_end {
        hasher.store(self.data, p, ref_wrap(self.ref_offset + p.to_int64()))
      }
      pos += found.length
    } else {
      pos += 1
      insert += 1
      if pos > random_at {
        let step = if pos > random_at + 256 { 4 } else { 2 }
        let jump = (pos + 4 * step).min(end - (7).max(step))
        while pos < jump {
          hasher.store(
            self.data,
            pos,
            ref_wrap(self.ref_offset + pos.to_int64()),
          )
          pos += step
          insert += step
        }
      }
    }
  }
  self.ref_insert = insert + end - pos
}
