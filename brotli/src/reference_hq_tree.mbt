// Port of google/brotli v1.2.1 c/enc/hash_to_binary_tree_inc.h (H10).
// Copyright 2016 Google Inc.; MIT, see LICENSE-encoder.

///|
priv struct HqTree {
  window_mask : UInt32
  invalid : UInt32
  buckets : FixedArray[UInt32]
  forest : FixedArray[UInt32]
  dictionary : HqDictionary
  matches : FixedArray[UInt32]
  mut count : Int32
  mut prepared : Bool
  peak : HqPeak?
}

///|
fn HqTree::new(
  window : Int32,
  input_size : Int32,
  one_shot : Bool,
  peak? : HqPeak,
) -> HqTree {
  let size = 1 << window
  let mask = (size - 1).reinterpret_as_uint()
  let invalid = 0U - mask
  {
    window_mask: mask,
    invalid,
    buckets: FixedArray::make(1 << 17, invalid),
    forest: FixedArray::make(
      2 * (if one_shot { size.min(input_size) } else { size }),
      0U,
    ),
    dictionary: HqDictionary::new(),
    matches: FixedArray::make(2 * 192, 0U),
    count: 0,
    prepared: true,
    peak,
  }
}

///|
fn HqTree::memory_usage(self : HqTree) -> Int32 {
  4 * (self.buckets.length() + self.forest.length() + self.matches.length()) +
  self.dictionary.memory_usage()
}

///|
fn HqTree::prepare(self : HqTree) -> Unit {
  if !self.prepared {
    self.buckets.fill(self.invalid)
    self.prepared = true
  }
}

///|
fn HqTree::add(
  self : HqTree,
  distance : Int32,
  length : Int32,
  code~ : Int32 = 0,
) -> Unit {
  self.matches[2 * self.count] = distance.reinterpret_as_uint()
  self.matches[2 * self.count + 1] = ((length << 5) |
  (if code == length { 0 } else { code })).reinterpret_as_uint()
  self.count += 1
}

///|
fn HqTree::search(
  self : HqTree,
  data : FixedArray[Byte],
  pos : Int32,
  absolute : UInt32,
  limit : Int32,
  reach : Int32,
  best : Int32,
  collect : Bool,
) -> Int32 {
  // find supplies the rest of the block. store_range and stitch only
  // pass positions with 128 bytes available. The tree holds prior positions
  // in the retained window.
  let comparison = limit.min(128)
  let reroot = limit >= 128
  // All callers leave at least four bytes. The hash selects one of 2^17 buckets.
  let key = ((ref_load4_hot(data, pos) * 0x1e35a7bdU) >> 15).reinterpret_as_int()
  let mut previous = ref_get(self.buckets, key)
  // Two children per position. The mask is within a full forest; a
  // shortened one-shot forest starts at absolute zero and covers all input
  // positions, including any earlier node reached by this search.
  let mut left = 2 * (absolute & self.window_mask).reinterpret_as_int()
  let mut right = left + 1
  let mut left_length = 0
  let mut right_length = 0
  let mut best = best
  if reroot {
    ref_set(self.buckets, key, absolute)
  }
  for depth = 64; ; depth = depth - 1 {
    let backward = (absolute - previous).to_uint64()
    if backward == 0UL || backward > reach.to_uint64() || depth == 0 {
      if reroot {
        ref_set(self.forest, left, self.invalid)
        ref_set(self.forest, right, self.invalid)
      }
      break
    }
    let prev = pos - backward.to_int()
    let common = left_length.min(right_length)
    let length = common +
      ref_match_length(data, prev + common, pos + common, limit - common)
    if collect && length > best {
      best = length
      self.add(backward.to_int(), length)
    }
    let child = 2 * (previous & self.window_mask).reinterpret_as_int()
    if length >= comparison {
      if reroot {
        ref_set(self.forest, left, ref_get(self.forest, child))
        ref_set(self.forest, right, ref_get(self.forest, child + 1))
      }
      break
    }
    // The match ended before comparison <= limit, and 0 <= prev < pos.
    if ref_get(data, pos + length) > ref_get(data, prev + length) {
      left_length = length
      if reroot {
        ref_set(self.forest, left, previous)
      }
      left = child + 1
      previous = ref_get(self.forest, left)
    } else {
      right_length = length
      if reroot {
        ref_set(self.forest, right, previous)
      }
      right = child
      previous = ref_get(self.forest, right)
    }
  }
  best
}

///|
fn HqTree::store_range(
  self : HqTree,
  data : FixedArray[Byte],
  origin : Int32,
  absolute : UInt32,
  start : Int32,
  end : Int32,
) -> Unit {
  let mut i = start
  let mut j = start
  if start + 63 <= end {
    i = end - 63
  }
  if start + 512 <= i {
    while j < i {
      let _ = self.search(
        data,
        origin + j,
        absolute + j.reinterpret_as_uint(),
        128,
        self.window_mask.reinterpret_as_int() - 15,
        0,
        false,
      )
      j += 8
    }
  }
  while i < end {
    let _ = self.search(
      data,
      origin + i,
      absolute + i.reinterpret_as_uint(),
      128,
      self.window_mask.reinterpret_as_int() - 15,
      0,
      false,
    )
    i += 1
  }
}

///|
fn HqTree::stitch(
  self : HqTree,
  data : FixedArray[Byte],
  pos : Int32,
  absolute : UInt32,
  length : Int32,
) -> Unit {
  self.prepare()
  if length >= 3 && absolute >= 128U {
    for back = 127; back > 127 - length.min(127); back = back - 1 {
      let reach = self.window_mask.reinterpret_as_int() - back.max(15)
      let _ = self.search(
        data,
        pos - back,
        absolute - back.reinterpret_as_uint(),
        128,
        reach,
        0,
        false,
      )
    }
  }
}

///|
fn HqTree::find(
  self : HqTree,
  data : FixedArray[Byte],
  pos : Int32,
  absolute : UInt32,
  limit : Int32,
  reach : Int32,
  dictionary_reach : Int32,
  quality : Int32,
) -> Unit {
  self.count = 0
  let short_limit = if quality == 11 { 64 } else { 16 }
  let stop = if absolute < short_limit.reinterpret_as_uint() {
    absolute.reinterpret_as_int()
  } else {
    short_limit
  }
  let mut best = 1
  for back = 1; back < stop && best <= 2; back = back + 1 {
    if back > reach {
      break
    }
    let prev = pos - back
    if data[pos] != data[prev] || data[pos + 1] != data[prev + 1] {
      continue
    }
    // hq_parse retains the window and limits the match to the block end.
    let length = ref_match_length(data, prev, pos, limit)
    if length > best {
      best = length
      self.add(back, length)
    }
  }
  if best < limit {
    best = self.search(data, pos, absolute, limit, reach, best, true)
  }
  let minimum = (best + 1).max(4)
  if minimum <= limit.min(37) {
    self.dictionary.find(data, pos, minimum, limit)
    for length in minimum..<=limit.min(37) {
      let entry = self.dictionary.matches[length]
      if entry < 0xfffffff {
        let distance = dictionary_reach.to_int64() +
          (entry >> 5).to_int64() +
          1L
        if distance <= MAX_CODED_DISTANCE.to_int64() {
          self.add(distance.to_int(), length, code=entry & 31)
        }
      }
    }
  }
}
