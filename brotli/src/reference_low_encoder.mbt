// google/brotli v1.2.1 encode.c and brotli_bit_stream.c, qualities 0..3.
// Copyright 2013, 2015 Google Inc.; MIT, see LICENSE-encoder.

///|
fn Encoder::fragment_append(self : Encoder, start : Int32, n : Int32) -> Unit {
  if self.data.length() < n + 8 {
    self.data = FixedArray::make(n + 8, b'\x00')
  }
  FixedArray::unsafe_blit(self.data, 0, self.ref_batch, start, n)
  self.data.fill(b'\x00', start=n, end=n + 8)
  self.data_len = n
}

///|
fn Encoder::fragment_process(self : Encoder, last : Bool) -> Unit {
  if !self.header_written {
    self.writer.write(4, ((self.window_bits.max(18) - 17) << 1) | 1)
    self.header_written = true
  }
  let n = self.data_len
  if n == 0 && !last {
    return
  }
  let arena = match self.low_arena().fragment {
    Some(a) => a
    None => {
      let a = FragmentArena::new()
      self.low_arena().fragment = Some(a)
      a
    }
  }
  arena.prepare(self.quality, n)
  let offset = self.writer.position() & 7
  let w = LowBits::new(2 * n + 503, offset~)
  if self.quality == 0 {
    arena.one_pass(w, self.data, n, last)
  } else {
    arena.two_pass(w, self.data, n, last)
  }
  w.append_to(self.writer, offset)
  self.data_len = 0
  self.ref_processed = 0
  self.block_start = 0
}

///|
fn Encoder::quick_process(self : Encoder, last : Bool, flush : Bool) -> Unit {
  let commands = self.ref_commands.unwrap()
  let mut start = self.ref_processed
  let end = self.data_len
  let length = end - start
  if length == 0 && !last && !flush {
    return
  }
  let hasher = match self.low_arena().quick {
    Some(h) => h
    None => {
      let h = QuickHasher::new(self.quality)
      self.low_arena().quick = Some(h)
      h
    }
  }
  hasher.prepare()
  if length >= 7 && self.ref_offset + start.to_int64() >= 3L {
    for p in (start - 3)..<start {
      hasher.store(self.data, p, ref_wrap(self.ref_offset + p.to_int64()))
    }
  }
  if !commands.is_empty() && self.ref_insert == 0 {
    let cmd = commands[commands.length() - 1]
    let distance = self.ref_distances[0]
    let reach = (self.ref_offset + start.to_int64() - cmd.copy.to_int64()).min(
      self.max_distance.to_int64(),
    )
    if (cmd.raw_distance < 16 || cmd.raw_distance - 15 == distance) &&
      distance.to_int64() <= reach {
      let more = ref_match_length(
        self.data,
        start - distance,
        start,
        end - start,
      )
      cmd.copy += more
      cmd.copy_code += more
      cmd.symbol = command_symbol(
        insert_code(cmd.insert),
        copy_code(cmd.copy_code),
        cmd.distance == 0,
      )
      start += more
    }
  }
  if start < end {
    self.quick_parse(hasher, start, end)
  }
  if ref_wrap(self.ref_offset + end.to_int64()) <
    ref_wrap(self.ref_offset + self.ref_processed.to_int64()) {
    hasher.prepared = false
  }
  self.ref_processed = end
  let max_meta = ref_max_meta(self.quality, self.window_bits)
  if !last &&
    !flush &&
    self.ref_literals + commands.length() < 12287 &&
    end - self.block_start + 16384 <= max_meta &&
    self.ref_literals < max_meta / 8 &&
    commands.length() < max_meta / 8 {
    return
  }
  if self.ref_insert > 0 {
    commands.push(RefCommand::new(self.ref_insert, 0, 4, 16))
    self.ref_literals += self.ref_insert
    self.ref_insert = 0
  }
  self.write_header()
  self.ref_emit(last)
  self.block_start = end
  commands.clear()
  self.ref_literals = 0
  for i in 0..<4 {
    self.ref_saved_distances[i] = self.ref_distances[i]
  }
}

///|
fn Encoder::low_store(self : Encoder, last : Bool) -> Unit {
  let commands = self.ref_commands.unwrap()
  let start = self.block_start
  let end = self.data_len
  let offset = self.writer.position() & 7
  let w = LowBits::new(2 * (end - start) + 4096, offset~)
  w.write(1, if last { 1 } else { 0 })
  if last {
    w.write(1, 0)
  }
  let nibbles = if end - start <= 65536 {
    4
  } else if end - start <= 1048576 {
    5
  } else {
    6
  }
  w.write(2, nibbles - 4)
  w.write(4 * nibbles, end - start - 1)
  if !last {
    w.write(1, 0)
  }
  w.write(13, 0)
  let lh = FixedArray::make(256, 0)
  let ch = FixedArray::make(704, 0)
  let dh = FixedArray::make(64, 0)
  let mut pos = start
  for cmd in commands {
    ch[cmd.symbol] += 1
    for i in 0..<cmd.insert {
      lh[self.data[pos + i].to_int()] += 1
    }
    pos += cmd.insert + cmd.copy
    if cmd.copy > 0 && cmd.symbol >= 128 {
      dh[cmd.distance] += 1
    }
  }
  let (lit, cmds, dist) = if self.quality == 2 {
    let tables = match self.low_arena().tables {
      Some(t) => t
      None => {
        let t = LowTables::new()
        self.low_arena().tables = Some(t)
        t
      }
    }
    let lit = w.fast_tree(tables, lh, 8)
    if commands.length() <= 128 {
      w.write(32, 0x16307003)
      w.write(24, 0x926244)
      w.write(3, 0)
      w.write(28, 0x0369dc03)
      (lit, tables.command, tables.distance)
    } else {
      (lit, w.fast_tree(tables, ch, 10), w.fast_tree(tables, dh, 6))
    }
  } else {
    (w.ordinary_tree(lh), w.ordinary_tree(ch), w.ordinary_tree(dh))
  }
  pos = start
  for cmd in commands {
    w.write(cmds.depths[cmd.symbol], cmds.bits[cmd.symbol])
    let ic = insert_code(cmd.insert)
    let cc = copy_code(cmd.copy_code)
    w.write(insert_length_extra[ic], cmd.insert - insert_length_base[ic])
    w.write(copy_length_extra[cc], cmd.copy_code - copy_length_base[cc])
    for _ in 0..<cmd.insert {
      let b = self.data[pos].to_int()
      pos += 1
      w.write(lit.depths[b], lit.bits[b])
    }
    pos += cmd.copy
    if cmd.copy > 0 && cmd.symbol >= 128 {
      w.write(dist.depths[cmd.distance], dist.bits[cmd.distance])
      w.write(distance_extra_bits(cmd.distance), cmd.extra)
    }
  }
  if last {
    w.align()
  }
  w.append_to(self.writer, offset)
}

///|
fn LowTables::memory_usage(self : LowTables) -> Int32 {
  4 *
  (
    self.length_depth.length() +
    self.length_bits.length() +
    self.zero_depth.length() +
    self.zero_bits.length() +
    self.nonzero_depth.length() +
    self.nonzero_bits.length() +
    self.command.depths.length() +
    self.command.bits.length() +
    self.distance.depths.length() +
    self.distance.bits.length()
  )
}

///|
fn FragmentArena::memory_usage(self : FragmentArena) -> Int32 {
  self.tables.memory_usage() +
  self.cache.data.length() +
  self.literals.length() +
  4 *
  (
    self.table.length() +
    self.depth.length() +
    self.codes.length() +
    self.histogram.length() +
    self.literal.depths.length() +
    self.literal.bits.length() +
    self.commands.length() +
    self.extra.length()
  )
}

///|
fn QuickHasher::memory_usage(self : QuickHasher) -> Int32 {
  4 * self.buckets.length() + 2 * self.words.length() + self.lengths.length()
}
