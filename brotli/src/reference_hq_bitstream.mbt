// Port of google/brotli v1.2.1 c/enc/metablock.c and brotli_bit_stream.c.
// Copyright 2013, 2015 Google Inc.; MIT, see LICENSE-encoder.

///|
fn hq_distance(
  code : Int32,
  direct : Int32,
  postfix : Int32,
) -> (Int32, Int32, Int32) {
  if code < 16 + direct {
    return (code, 0, 0)
  }
  let dist = (1 << (postfix + 2)) + code - 16 - direct
  let bucket = 30 - dist.clz()
  let post = dist & ((1 << postfix) - 1)
  let prefix = (dist >> bucket) & 1
  let offset = (2 + prefix) << bucket
  let bits = bucket - postfix
  (
    16 + direct + ((2 * (bits - 1) + prefix) << postfix) + post,
    (dist - offset) >> postfix,
    bits,
  )
}

///|
fn hq_distance_params(
  commands : Array[RefCommand],
  memory? : HqMemory,
) -> (Int32, Int32) {
  let mark = hq_memory_mark(memory)
  defer hq_memory_restore(memory, mark)
  let hist = HqHistogram::new(544)
  hq_memory_add(memory, hist.memory_usage())
  let mut msb = 0
  let mut best = 1.0e99
  let mut chosen = (0, 0)
  for post in 0..<=3 {
    while msb < 16 {
      let direct = msb << post
      hist.clear()
      let mut extra = 0.0
      let mut valid = true
      let limit = direct + (1 << (26 + post)) - (1 << (2 + post))
      for cmd in commands {
        if cmd.copy > 0 && cmd.symbol >= 128 {
          // The original (0,0) prefixes are already valid. The reference
          // checks the distance limit only when trying different parameters.
          if cmd.raw_distance > limit && (post != 0 || direct != 0) {
            valid = false
            break
          }
          let (sym, _, bits) = hq_distance(cmd.raw_distance, direct, post)
          hist.add(sym)
          extra += bits.to_double()
        }
      }
      let cost = hist.population(memory?) + extra
      if !valid || cost > best {
        break
      }
      best = cost
      chosen = (direct, post)
      msb += 1
    }
    if msb > 0 {
      msb -= 1
    }
    msb /= 2
  }
  chosen
}

///|
fn hq_distance_context(cmd : RefCommand) -> Int32 {
  let r = cmd.symbol >> 6
  let c = cmd.symbol & 7
  if (r == 0 || r == 2 || r == 4 || r == 7) && c <= 2 {
    c
  } else {
    3
  }
}

///|
priv struct HqBlockCursor {
  split : RefSplit
  mut block : Int32
  mut remaining : Int32
}

///|
fn HqBlockCursor::new(split : RefSplit) -> HqBlockCursor {
  { split, block: 0, remaining: split.lengths[0], }
}

///|
fn HqBlockCursor::next(self : HqBlockCursor) -> Int32 {
  if self.remaining == 0 {
    self.block += 1
    self.remaining = self.split.lengths[self.block]
  }
  self.remaining -= 1
  self.split.types[self.block]
}

///|
fn RefBlockWriter::hq_symbol(
  self : RefBlockWriter,
  w : @bits.BitPacker,
  symbol : Int32,
  context : Int32,
  context_bits : Int32,
  map : FixedArray[Int32],
) -> Unit {
  if self.remaining == 0 {
    self.block += 1
    let value = self.split.types[self.block]
    let code = ref_next_type(value, self.last, self.second)
    self.second = self.last
    self.last = value
    self.type_code.write(w, code)
    let n = self.split.lengths[self.block]
    let sym = ref_block_code(n)
    self.length_code.write(w, sym)
    w.write(@rules.block_count_extra_bits(sym), n - @rules.block_count(sym, 0))
    self.remaining = n
  }
  self.remaining -= 1
  let tree = map[(self.split.types[self.block] << context_bits) + context]
  self.codes[tree].write(w, symbol)
}

///|
fn hq_write_map(
  w : @bits.BitPacker,
  map : FixedArray[Int32],
  count : Int32,
) -> Unit {
  if count == 1 {
    ref_varuint(w, 0)
  } else {
    ref_write_map(w, map, count)
  }
}

///|
fn hq_trees(
  writer : RefBlockWriter,
  w : @bits.BitPacker,
  hist : Array[HqHistogram],
  alphabet : Int32,
) -> Unit {
  for h in hist {
    let counts = FixedArray::makei(alphabet, i => h.data[i])
    ref_optimize_counts(counts)
    writer.codes.push(ref_write_code(w, counts))
  }
}

///|
fn hq_store_block(
  w : @bits.BitPacker,
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
  commands : Array[RefCommand],
  quality : Int32,
  is_last : Bool,
  memory? : HqMemory,
) -> Unit {
  let mark = hq_memory_mark(memory)
  defer hq_memory_restore(memory, mark)
  let (direct, post) = hq_distance_params(commands, memory?)
  let alphabet = 16 + direct + (48 << post)
  let mode = if hq_mostly_utf8(data, start, end - start) { 2 } else { 3 }
  let literal_values : Array[Int32] = []
  let command_values = FixedArray::makei(commands.length(), i => {
    commands[i].symbol
  })
  let distance_values : Array[Int32] = []
  let mut pos = start
  for cmd in commands {
    for _ in 0..<cmd.insert {
      literal_values.push(data[pos].to_int())
      pos += 1
    }
    pos += cmd.copy
    if cmd.copy > 0 && cmd.symbol >= 128 {
      let (sym, _, _) = hq_distance(cmd.raw_distance, direct, post)
      distance_values.push(sym)
    }
  }
  let literal_capacity = literal_values.capacity()
  let distance_capacity = distance_values.capacity()
  hq_memory_add(
    memory,
    4L *
    (literal_capacity + command_values.length() + distance_capacity).to_int64(),
  )
  let literal_symbols = FixedArray::from_array(literal_values)
  hq_memory_handoff(memory, literal_capacity, literal_symbols.length())
  let literals = hq_split(
    literal_symbols,
    256,
    quality,
    544,
    100,
    70,
    28.1,
    memory?,
  )
  hq_memory_add(
    memory,
    literals.hq_memory_usage() - 4L * literal_symbols.length().to_int64(),
  )
  let cmds = hq_split(command_values, 704, quality, 530, 50, 40, 13.5, memory?)
  hq_memory_add(
    memory,
    cmds.hq_memory_usage() - 4L * command_values.length().to_int64(),
  )
  let distance_symbols = FixedArray::from_array(distance_values)
  hq_memory_handoff(memory, distance_capacity, distance_symbols.length())
  let distances = hq_split(
    distance_symbols,
    544,
    quality,
    544,
    50,
    40,
    14.6,
    memory?,
  )
  hq_memory_add(
    memory,
    distances.hq_memory_usage() - 4L * distance_symbols.length().to_int64(),
  )
  let lh = Array::makei(literals.hist.length() * 64, _ => HqHistogram::new(256))
  let ch = Array::makei(cmds.hist.length(), _ => HqHistogram::new(704))
  let dh = Array::makei(distances.hist.length() * 4, _ => HqHistogram::new(544))
  hq_memory_add(
    memory,
    hq_histograms_memory(lh) +
    hq_histograms_memory(ch) +
    hq_histograms_memory(dh),
  )
  let lc = HqBlockCursor::new(literals)
  let cc = HqBlockCursor::new(cmds)
  let dc = HqBlockCursor::new(distances)
  pos = start
  let mut p1 = if start > 0 { data[start - 1].to_int() } else { 0 }
  let mut p2 = if start > 1 { data[start - 2].to_int() } else { 0 }
  for cmd in commands {
    ch[cc.next()].add(cmd.symbol)
    for _ in 0..<cmd.insert {
      let b = data[pos].to_int()
      lh[(lc.next() << 6) + literal_context(mode, p1, p2)].add(b)
      p2 = p1
      p1 = b
      pos += 1
    }
    pos += cmd.copy
    if cmd.copy > 0 {
      p2 = data[pos - 2].to_int()
      p1 = data[pos - 1].to_int()
      if cmd.symbol >= 128 {
        let (sym, _, _) = hq_distance(cmd.raw_distance, direct, post)
        dh[(dc.next() << 2) + hq_distance_context(cmd)].add(sym)
      }
    }
  }
  let old_lh = hq_histograms_memory(lh)
  let (lh, lmap) = hq_cluster(lh, memory?)
  hq_memory_add(
    memory,
    hq_histograms_memory(lh) + 4L * lmap.length().to_int64() - old_lh,
  )
  let old_dh = hq_histograms_memory(dh)
  let (dh, dmap) = hq_cluster(dh, memory?)
  hq_memory_add(
    memory,
    hq_histograms_memory(dh) + 4L * dmap.length().to_int64() - old_dh,
  )
  // Bound the remaining small Huffman/map helpers separately. Measurement
  // accepts a peak only when this entire envelope is below an observed peak;
  // a bound is never reported as if it were an observed allocation.
  let trees_upper = 8L *
    (256 * lh.length() + 704 * ch.length() + alphabet * dh.length()).to_int64() +
    32L *
    (lh.length() + ch.length() + dh.length() + lmap.length() + dmap.length()).to_int64() +
    128L * 704L +
    8192L
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
  w.write(2, post)
  w.write(4, direct >> post)
  for _ in 0..<literals.hist.length() {
    w.write(2, mode)
  }
  hq_write_map(w, lmap, lh.length())
  hq_write_map(w, dmap, dh.length())
  hq_trees(lw, w, lh, 256)
  hq_trees(cw, w, ch, 704)
  hq_trees(dw, w, dh, alphabet)
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
      lw.hq_symbol(w, b, literal_context(mode, p1, p2), 6, lmap)
      p2 = p1
      p1 = b
      pos += 1
    }
    pos += cmd.copy
    if cmd.copy > 0 {
      p2 = data[pos - 2].to_int()
      p1 = data[pos - 1].to_int()
      if cmd.symbol >= 128 {
        let (sym, extra, bits) = hq_distance(cmd.raw_distance, direct, post)
        dw.hq_symbol(w, sym, hq_distance_context(cmd), 2, dmap)
        w.write(bits, extra)
      }
    }
  }
  if is_last {
    w.align()
  }
  if memory is Some(m) {
    m.peak.trees_upper = m.peak.trees_upper.max(
      m.owner.memory_usage().to_int64() + m.live + trees_upper,
    )
  }
}
