// google/brotli v1.2.1 compress_fragment{,_two_pass}.c and encode.c.
// Copyright 2015 Google Inc.; MIT, see LICENSE-encoder.

///|
priv struct FragmentArena {
  tables : LowTables
  mut table : FixedArray[Int32]
  mut bits : Int32
  depth : FixedArray[Int32]
  codes : FixedArray[Int32]
  histogram : FixedArray[Int32]
  mut literal : RefCode
  mut cache : LowBits
  mut commands : FixedArray[Int32]
  mut literals : FixedArray[Byte]
  mut command_count : Int32
  mut literal_count : Int32
  extra : FixedArray[Int32]
}

///|
fn FragmentArena::new() -> FragmentArena {
  let cache = LowBits::new(512)
  let initial = low_default_code()
  for i in 0..<56 {
    cache.write(8, initial[i])
  }
  {
    tables: LowTables::new(),
    table: [],
    bits: 0,
    depth: low_default_depth(),
    codes: low_default_bits(),
    histogram: low_command_seed(),
    literal: {
      depths: FixedArray::make(256, 0),
      bits: FixedArray::make(256, 0),
    },
    cache,
    commands: [],
    literals: [],
    command_count: 0,
    literal_count: 0,
    extra: low_extra_bits(),
  }
}

///|
fn FragmentArena::prepare(
  self : FragmentArena,
  quality : Int32,
  size : Int32,
) -> Unit {
  let mut bits = 8
  while 1 << bits < size && bits < (if quality == 0 { 15 } else { 17 }) {
    bits += 1
  }
  if quality == 0 && (bits & 1) == 0 {
    bits += 1
  }
  self.bits = bits
  let count = 1 << bits
  if self.table.length() < count {
    self.table = FixedArray::make(count, 0)
  } else {
    self.table.fill(0, start=0, end=count)
  }
  if quality == 1 {
    let n = size.min(131072)
    if self.commands.length() < n {
      self.commands = FixedArray::make(n, 0)
      self.literals = FixedArray::make(n, b'\x00')
    }
  }
}

///|
fn FragmentArena::command_tree(
  self : FragmentArena,
  writer : LowBits,
  two_pass : Bool,
) -> Unit {
  let a = ref_code(FixedArray::makei(64, i => self.histogram[i]))
  let b = ref_code(FixedArray::makei(64, i => self.histogram[i + 64]), limit=14)
  for i in 0..<64 {
    self.depth[i] = a.depths[i]
    self.depth[i + 64] = b.depths[i]
  }
  let groups = if two_pass {
    [3, 4, 5, 0, 6, 1, 7, 2]
  } else {
    [0, 1, 2, 5, 3, 6, 4, 7]
  }
  let tmp = FixedArray::makei(64, i => self.depth[groups[i / 8] * 8 + (i & 7)])
  let bits = low_symbols(tmp)
  for i in 0..<64 {
    self.codes[groups[i / 8] * 8 + (i & 7)] = bits[i]
    self.codes[i + 64] = b.bits[i]
  }
  let full = FixedArray::make(704, 0)
  let from = if two_pass { [3, 4, 5, 6, 7] } else { [0, 1, 2, 3, 4] }
  for j, dest in [0, 64, 128, 192, 384] {
    for i in 0..<8 {
      full[dest + i] = self.depth[8 * from[j] + i]
    }
  }
  for j, dest in [128, 256, 448] {
    let group = if two_pass { j } else { j + 5 }
    for i in 0..<8 {
      full[dest + 8 * i] = self.depth[8 * group + i]
    }
  }
  writer.standard_tree(full)
  writer.standard_tree(b.depths)
}

///|
fn fragment_insert(n : Int32) -> (Int32, Int32) {
  if n < 6 {
    (n, 0)
  } else if n < 130 {
    let tail = n - 2
    let b = 30 - tail.clz()
    let p = tail >> b
    ((b << 1) + p + 2, tail - (p << b))
  } else if n < 2114 {
    let tail = n - 66
    let b = 31 - tail.clz()
    (b + 10, tail - (1 << b))
  } else if n < 6210 {
    (21, n - 2114)
  } else if n < 22594 {
    (22, n - 6210)
  } else {
    (23, n - 22594)
  }
}

///|
fn fragment_copy(n : Int32) -> (Int32, Int32) {
  if n < 10 {
    (n + 38, 0)
  } else if n < 134 {
    let t = n - 6
    let b = 30 - t.clz()
    let p = t >> b
    ((b << 1) + p + 44, t - (p << b))
  } else if n < 2118 {
    let t = n - 70
    let b = 31 - t.clz()
    (b + 52, t - (1 << b))
  } else {
    (63, n - 2118)
  }
}

///|
fn fragment_last_copy(n : Int32) -> (Int32, Int32, Bool) {
  if n < 12 {
    (n + 20, 0, false)
  } else if n < 72 {
    let t = n - 8
    let b = 30 - t.clz()
    let p = t >> b
    ((b << 1) + p + 28, t - (p << b), false)
  } else if n < 136 {
    let t = n - 8
    ((t >> 5) + 54, t & 31, true)
  } else if n < 2120 {
    let t = n - 72
    let b = 31 - t.clz()
    (b + 52, t - (1 << b), true)
  } else {
    (63, n - 2120, true)
  }
}

///|
fn fragment_distance(n : Int32) -> (Int32, Int32) {
  let d = n + 3
  let b = 30 - d.clz()
  let p = (d >> b) & 1
  (2 * (b - 1) + p + 80, d - ((2 + p) << b))
}

///|
fn FragmentArena::one_code(
  self : FragmentArena,
  w : LowBits,
  code : Int32,
  extra : Int32,
  width : Int32,
) -> Unit {
  w.write(self.depth[code], self.codes[code])
  w.write(width, extra)
  self.histogram[code] += 1
}

///|
fn FragmentArena::insert0(self : FragmentArena, w : LowBits, n : Int32) -> Unit {
  let (code, extra) = fragment_insert(n)
  self.one_code(w, code + 40, extra, self.extra[code])
}

///|
fn FragmentArena::copy0(
  self : FragmentArena,
  w : LowBits,
  n : Int32,
  last : Bool,
) -> Unit {
  if last {
    let (code, extra, again) = fragment_last_copy(n)
    self.one_code(w, code - 24, extra, self.extra[code])
    if again {
      self.one_code(w, 64, 0, 0)
    }
  } else {
    let (code, extra) = fragment_copy(n)
    self.one_code(w, code - 24, extra, self.extra[code])
  }
}

///|
fn FragmentArena::distance0(
  self : FragmentArena,
  w : LowBits,
  n : Int32,
) -> Unit {
  let (code, extra) = fragment_distance(n)
  self.one_code(w, code, extra, self.extra[code])
}

///|
fn FragmentArena::literal0(
  self : FragmentArena,
  w : LowBits,
  data : FixedArray[Byte],
  start : Int32,
  n : Int32,
) -> Unit {
  for p in start..<(start + n) {
    let b = data[p].to_int()
    w.write(self.literal.depths[b], self.literal.bits[b])
  }
}

///|
fn FragmentArena::push1(
  self : FragmentArena,
  code : Int32,
  extra : Int32,
) -> Unit {
  self.commands[self.command_count] = code | (extra << 8)
  self.command_count += 1
}
