// Port of google/brotli v1.2.1 c/enc/brotli_bit_stream.c.
// Copyright 2013 Google Inc.; MIT, see LICENSE-encoder.

///|
fn ref_varuint(w : @bits.BitPacker, n : Int32) -> Unit {
  if n == 0 {
    w.write(1, 0)
  } else {
    let bits = 31 - n.clz()
    w.write(1, 1)
    w.write(3, bits)
    w.write(bits, n - (1 << bits))
  }
}

///|
fn ref_length(w : @bits.BitPacker, n : Int32) -> Unit {
  let bits = (32 - (n - 1).max(1).clz()).max(16)
  let nibbles = (bits + 3) / 4
  w.write(2, nibbles - 4)
  w.write(nibbles * 4, n - 1)
}

///|
fn ref_trivial_map(
  w : @bits.BitPacker,
  types : Int32,
  context_bits : Int32,
) -> Unit {
  ref_varuint(w, types - 1)
  if types == 1 {
    return
  }
  let repeat = context_bits - 1
  let hist = FixedArray::make(types + repeat, 0)
  hist[repeat] = types
  hist[0] = 1
  for i in context_bits..<hist.length() {
    hist[i] = 1
  }
  w.write(1, 1)
  w.write(4, repeat - 1)
  let code = ref_write_code(w, hist)
  for i in 0..<types {
    code.write(w, if i == 0 { 0 } else { i + repeat })
    code.write(w, repeat)
    w.write(repeat, (1 << repeat) - 1)
  }
  w.write(1, 1)
}

///|
fn ref_write_map(
  w : @bits.BitPacker,
  map : FixedArray[Int32],
  clusters : Int32,
) -> Unit {
  ref_varuint(w, clusters - 1)
  let mtf = FixedArray::makei(clusters, i => i)
  let values = FixedArray::makei(map.length(), i => {
    let value = map[i]
    let mut at = 0
    while mtf[at] != value {
      at += 1
    }
    let index = at
    while at > 0 {
      mtf[at] = mtf[at - 1]
      at -= 1
    }
    mtf[0] = value
    index
  })
  let mut max_run = 0
  let mut run = 0
  for value in values {
    if value == 0 {
      run += 1
      max_run = max_run.max(run)
    } else {
      run = 0
    }
  }
  let prefix = if max_run == 0 { 0 } else { (31 - max_run.clz()).min(6) }
  let symbols = Array()
  let extras = Array()
  let mut i = 0
  while i < values.length() {
    if values[i] != 0 {
      symbols.push(values[i] + prefix)
      extras.push(0)
      i += 1
    } else {
      let mut run = 1
      while i + run < values.length() && values[i + run] == 0 {
        run += 1
      }
      i += run
      while run != 0 {
        if run < 2 << prefix {
          let bits = 31 - run.clz()
          symbols.push(bits)
          extras.push(run - (1 << bits))
          break
        } else {
          symbols.push(prefix)
          extras.push((1 << prefix) - 1)
          run -= (2 << prefix) - 1
        }
      }
    }
  }
  w.write(1, if prefix > 0 { 1 } else { 0 })
  if prefix > 0 {
    w.write(4, prefix - 1)
  }
  let hist = FixedArray::make(clusters + prefix, 0)
  for s in symbols {
    hist[s] += 1
  }
  let code = ref_write_code(w, hist)
  for j in 0..<symbols.length() {
    let s = symbols[j]
    code.write(w, s)
    if s > 0 && s <= prefix {
      w.write(s, extras[j])
    }
  }
  w.write(1, 1)
}

///|
fn ref_block_code(n : Int32) -> Int32 {
  let mut code = 0
  while code < 25 && n >= @rules.block_count(code + 1, 0) {
    code += 1
  }
  code
}

///|
priv struct RefBlockWriter {
  split : RefSplit
  type_code : RefCode
  length_code : RefCode
  codes : Array[RefCode]
  mut block : Int32
  mut remaining : Int32
  mut last : Int32
  mut second : Int32
}

///|
fn ref_next_type(value : Int32, last : Int32, second : Int32) -> Int32 {
  if value == last + 1 {
    1
  } else if value == second {
    0
  } else {
    value + 2
  }
}

///|
fn RefBlockWriter::header(
  split : RefSplit,
  w : @bits.BitPacker,
) -> RefBlockWriter {
  let types = split.hist.length()
  let th = FixedArray::make(types + 2, 0)
  let lh = FixedArray::make(26, 0)
  let mut last = 1
  let mut second = 0
  for i, value in split.types {
    let tc = ref_next_type(value, last, second)
    second = last
    last = value
    if i != 0 {
      th[tc] += 1
    }
    lh[ref_block_code(split.lengths[i])] += 1
  }
  ref_varuint(w, types - 1)
  let (type_code, length_code) = if types > 1 {
    let tc = ref_write_code(w, th)
    let lc = ref_write_code(w, lh)
    let n = split.lengths[0]
    let sym = ref_block_code(n)
    lc.write(w, sym)
    w.write(@rules.block_count_extra_bits(sym), n - @rules.block_count(sym, 0))
    (tc, lc)
  } else {
    (ref_code(th), ref_code(lh))
  }
  {
    split,
    type_code,
    length_code,
    codes: Array(),
    block: 0,
    remaining: split.lengths[0],
    last: 0,
    second: 1,
  }
}

///|
fn RefBlockWriter::trees(self : RefBlockWriter, w : @bits.BitPacker) -> Unit {
  for hist in self.split.hist {
    for c in 0..<self.split.contexts {
      let h = FixedArray::makei(self.split.alphabet, i => {
        hist[c * self.split.alphabet + i]
      })
      ref_optimize_counts(h)
      self.codes.push(ref_write_code(w, h))
    }
  }
}

///|
fn RefBlockWriter::symbol(
  self : RefBlockWriter,
  w : @bits.BitPacker,
  symbol : Int32,
  context~ : Int32 = 0,
) -> Unit {
  if self.remaining == 0 {
    self.block += 1
    let value = self.split.types[self.block]
    let code = ref_next_type(value, self.last, self.second)
    self.second = self.last
    self.last = value
    self.type_code.write(w, code)
    let n = self.split.lengths[self.block]
    let s = ref_block_code(n)
    self.length_code.write(w, s)
    w.write(@rules.block_count_extra_bits(s), n - @rules.block_count(s, 0))
    self.remaining = n
  }
  self.remaining -= 1
  self.codes[self.split.types[self.block] * self.split.contexts + context].write(
    w, symbol,
  )
}

///|
priv struct RefCommand {
  insert : Int32
  mut copy : Int32
  mut copy_code : Int32
  mut symbol : Int32
  distance : Int32
  extra : Int32
  raw_distance : Int32
}

///|
fn RefCommand::new(
  insert : Int32,
  copy : Int32,
  delta : Int32,
  distance_code : Int32,
) -> RefCommand {
  let actual = distance_code - 15
  let distance = if distance_code < 16 {
    distance_code
  } else {
    distance_symbol(actual)
  }
  let extra = if distance_code < 16 { 0 } else { distance_extra(actual) }
  let length_code = copy + delta
  {
    insert,
    copy,
    copy_code: length_code,
    symbol: command_symbol(
      insert_code(insert),
      copy_code(length_code),
      distance == 0,
    ),
    distance,
    extra,
    raw_distance: distance_code,
  }
}

///|
fn ref_store_block(
  w : @bits.BitPacker,
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
  commands : Array[RefCommand],
  quality : Int32,
  hint : Int64,
  is_last : Bool,
) -> Unit {
  let (contexts, map) = ref_context_map(data, start, end, quality, hint)
  let literals = RefSplit::new(256, contexts, 512, 400.0)
  let cmds = RefSplit::new(704, 1, 1024, 500.0)
  let distances = RefSplit::new(64, 1, 512, 100.0)
  let mut pos = start
  let mut p1 = if start > 0 { data[start - 1].to_int() } else { 0 }
  let mut p2 = if start > 1 { data[start - 2].to_int() } else { 0 }
  for cmd in commands {
    cmds.add(cmd.symbol)
    for _ in 0..<cmd.insert {
      let b = data[pos].to_int()
      literals.add(
        b,
        context=if contexts == 1 { 0 } else { map[literal_context(2, p1, p2)] },
      )
      p2 = p1
      p1 = b
      pos += 1
    }
    pos += cmd.copy
    if cmd.copy > 0 {
      p2 = data[pos - 2].to_int()
      p1 = data[pos - 1].to_int()
      if cmd.symbol >= 128 {
        distances.add(cmd.distance)
      }
    }
  }
  literals.finish()
  cmds.finish()
  distances.finish()
  w.write(1, if is_last { 1 } else { 0 })
  if is_last {
    w.write(1, 0)
  }
  ref_length(w, end - start)
  if !is_last {
    w.write(1, 0)
  }
  let lw = RefBlockWriter::header(literals, w)
  let cw = RefBlockWriter::header(cmds, w)
  let dw = RefBlockWriter::header(distances, w)
  w.write(6, 0)
  for _ in 0..<literals.hist.length() {
    w.write(2, 2)
  }
  if contexts == 1 {
    ref_trivial_map(w, literals.hist.length(), 6)
  } else {
    ref_write_map(
      w,
      FixedArray::makei(literals.hist.length() * 64, i => {
        (i >> 6) * contexts + map[i & 63]
      }),
      literals.hist.length() * contexts,
    )
  }
  ref_trivial_map(w, distances.hist.length(), 2)
  lw.trees(w)
  cw.trees(w)
  dw.trees(w)
  pos = start
  p1 = if start > 0 { data[start - 1].to_int() } else { 0 }
  p2 = if start > 1 { data[start - 2].to_int() } else { 0 }
  for cmd in commands {
    cw.symbol(w, cmd.symbol)
    let ic = insert_code(cmd.insert)
    let cc = copy_code(cmd.copy_code)
    w.write(insert_length_extra[ic], cmd.insert - insert_length_base[ic])
    w.write(copy_length_extra[cc], cmd.copy_code - copy_length_base[cc])
    for _ in 0..<cmd.insert {
      let b = data[pos].to_int()
      lw.symbol(
        w,
        b,
        context=if contexts == 1 { 0 } else { map[literal_context(2, p1, p2)] },
      )
      p2 = p1
      p1 = b
      pos += 1
    }
    pos += cmd.copy
    if cmd.copy > 0 {
      p2 = data[pos - 2].to_int()
      p1 = data[pos - 1].to_int()
      if cmd.symbol >= 128 {
        dw.symbol(w, cmd.distance)
        if cmd.distance >= 16 {
          w.write(distance_extra_bits(cmd.distance), cmd.extra)
        }
      }
    }
  }
  if is_last {
    w.align()
  }
}
