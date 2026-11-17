// Port of google/brotli v1.2.1 c/enc/static_dict.c.
// Copyright 2013 Google Inc.; MIT, see LICENSE-encoder.

///|
priv struct HqDictionary {
  buckets : FixedArray[UInt16]
  words : FixedArray[UInt32]
  suffixes : FixedArray[Int32]
  groups : FixedArray[Int32]
  matches : FixedArray[Int32]
}

///|
fn HqDictionary::new() -> HqDictionary {
  let lists : Array[Array[Int32]] = [
    [
      1, 28, 46, 60, 10, 38, 16, 47, 25, 37, 8, 45, 80, 5, 29, 17, 35, 19, 21, 20,
      31, 43, 75, 76, 14, 22, 50, 24, 36, 51, 57, 70, 86, 84, 53, 82, 95, 90, 92,
      100, 93, 61, 106,
    ],
    [4, 66, 69, 79, 88, 99, 58, 74, 78, 104, 108],
    [68, 87, 97, 101, 114, 112, 107, 94, 113, 105, 116],
    [2, 89, 103, 33, 71, 52, 81, 98],
    [77, 67],
    [15, 109, 65, 96, 91, 118, 120],
    [83, 111, 115, 117, 110, 119],
  ]
  let suffixes = []
  let groups = [0]
  for list in lists {
    for t in list {
      suffixes.push(t)
    }
    groups.push(suffixes.length())
  }
  {
    buckets: hq_dict_buckets(),
    words: hq_dict_words(),
    suffixes: FixedArray::from_array(suffixes),
    groups: FixedArray::from_array(groups),
    matches: FixedArray::make(38, 0xfffffff),
  }
}

///|
fn HqDictionary::memory_usage(self : HqDictionary) -> Int32 {
  2 * self.buckets.length() +
  4 *
  (
    self.words.length() +
    self.suffixes.length() +
    self.groups.length() +
    self.matches.length()
  )
}

///|
fn HqDictionary::add(
  self : HqDictionary,
  id : Int32,
  length : Int32,
  code : Int32,
) -> Unit {
  self.matches[length] = self.matches[length].min((id << 5) + code)
}

///|
fn hq_bytes_equal(
  data : FixedArray[Byte],
  pos : Int32,
  bytes : BytesView,
) -> Bool {
  for i in 0..<bytes.length() {
    if data[pos + i] != bytes[i] {
      return false
    }
  }
  true
}

///|
fn hq_word_match(
  data : FixedArray[Byte],
  pos : Int32,
  limit : Int32,
  length : Int32,
  id : Int32,
  transform : Int32,
) -> Int32 {
  let offset = dictionary_offsets[length] + length * id
  let mut n = 0
  while n < length.min(limit) {
    let original = dictionary[offset + n].to_int()
    let expected = if (transform == 10 && n == 0) || transform == 11 {
      if original >= 97 && original <= 122 {
        original ^ 32
      } else {
        if transform == 10 {
          return 0
        }
        original
      }
    } else {
      original
    }
    if data[pos + n].to_int() != expected {
      break
    }
    n += 1
  }
  n
}

///|
fn HqDictionary::suffix(
  self : HqDictionary,
  data : FixedArray[Byte],
  pos : Int32,
  limit : Int32,
  prefix : Int32,
  length : Int32,
  id : Int32,
  group : Int32,
) -> Unit {
  let n = 1 << dictionary_size_bits[length]
  for i in self.groups[group]..<self.groups[group + 1] {
    let t = self.suffixes[i]
    let suffix = transform_suffixes[t]
    let size = prefix + length + suffix.length()
    if size <= limit && hq_bytes_equal(data, pos + prefix + length, suffix) {
      self.add(id + t * n, size, length)
    }
  }
}

///|
fn HqDictionary::find(
  self : HqDictionary,
  data : FixedArray[Byte],
  pos : Int32,
  min_length : Int32,
  limit : Int32,
) -> Unit {
  self.matches.fill(0xfffffff)
  // The four lookup positions and all length guards follow static_dict.c;
  // trying every RFC transform would admit matches the reference omits.
  for variant in 0..<4 {
    let prefix = if variant == 3 { 5 } else { variant }
    if prefix == 1 && (limit < 5 || (data[pos] != b' ' && data[pos] != b'.')) {
      continue
    }
    if prefix == 2 &&
      (
        limit < 6 ||
        !((
          data[pos + 1] == b' ' &&
          (data[pos] == b'e' || data[pos] == b's' || data[pos] == b',')
        ) ||
        (data[pos] == b'\xc2' && data[pos + 1] == b'\xa0'))
      ) {
      continue
    }
    if prefix == 5 &&
      (
        limit < 9 ||
        !(hq_bytes_equal(data, pos, b" the ") ||
        hq_bytes_equal(data, pos, b".com/"))
      ) {
      continue
    }
    let hash = ((ref_load4(data, pos + prefix) * 0x1e35a7bdU) >> 17).reinterpret_as_int()
    let mut at = self.buckets[hash].to_int()
    while at != 0 {
      let packed = self.words[at]
      let length = (packed & 31U).reinterpret_as_int()
      let kind = ((packed >> 8) & 255U).reinterpret_as_int()
      let id = (packed >> 16).reinterpret_as_int()
      at = if (packed & 128U) != 0U { 0 } else { at + 1 }
      let n = 1 << dictionary_size_bits[length]
      let matched = hq_word_match(
        data,
        pos + prefix,
        limit - prefix,
        length,
        id,
        kind,
      )
      if prefix == 0 {
        if kind == 0 {
          if matched == length {
            self.add(id, length, length)
          }
          if matched >= length - 1 {
            self.add(id + 12 * n, length - 1, length)
            if length + 2 < limit &&
              hq_bytes_equal(data, pos + length - 1, b"ing ") {
              self.add(id + 49 * n, length + 3, length)
            }
          }
          let minimum = if length > 9 {
            min_length.max(length - 9)
          } else {
            min_length
          }
          for size in minimum..<=matched.min(length - 2) {
            let cut = length - size
            let t = (cut << 2) +
              ((0x071b520ada2d3200UL >> (cut * 6)) & 63UL).to_int()
            self.add(id + t * n, size, length)
          }
          if matched == length && length + 6 < limit {
            self.suffix(data, pos, limit, 0, length, id, 0)
          }
        } else if matched == length {
          let all = kind != 10
          self.add(id + (if all { 44 } else { 9 }) * n, length, length)
          if length + 1 < limit {
            self.suffix(
              data,
              pos,
              limit,
              0,
              length,
              id,
              if all {
                2
              } else {
                1
              },
            )
          }
        }
      } else if prefix == 1 && matched == length {
        let space = data[pos] == b' '
        if kind == 0 {
          self.add(id + (if space { 6 } else { 32 }) * n, length + 1, length)
          if length + 2 < limit {
            self.suffix(
              data,
              pos,
              limit,
              1,
              length,
              id,
              if space {
                3
              } else {
                4
              },
            )
          }
        } else if space {
          let all = kind != 10
          self.add(id + (if all { 85 } else { 30 }) * n, length + 1, length)
          if length + 2 < limit {
            self.suffix(
              data,
              pos,
              limit,
              1,
              length,
              id,
              if all {
                6
              } else {
                5
              },
            )
          }
        }
      } else if prefix == 2 && kind == 0 && matched == length {
        if data[pos] == b'\xc2' {
          self.add(id + 102 * n, length + 2, length)
        } else if length + 2 < limit && data[pos + length + 2] == b' ' {
          let t = if data[pos] == b'e' {
            18
          } else if data[pos] == b's' {
            7
          } else {
            13
          }
          self.add(id + t * n, length + 3, length)
        }
      } else if prefix == 5 && kind == 0 && matched == length {
        let space = data[pos] == b' '
        self.add(id + (if space { 41 } else { 72 }) * n, length + 5, length)
        if space &&
          length + 8 < limit &&
          hq_bytes_equal(data, pos + length + 5, b" of ") {
          self.add(id + 62 * n, length + 9, length)
          if length + 12 < limit &&
            hq_bytes_equal(data, pos + length + 9, b"the ") {
            self.add(id + 73 * n, length + 13, length)
          }
        }
      }
    }
  }
}
