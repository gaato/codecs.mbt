// Compressing one meta-block: a greedy parse into commands, then one prefix
// code per category (one block type each, no context modeling, no
// dictionary references), and a fallback to an uncompressed meta-block when
// that comes out smaller.

///|
/// The input of one meta-block, at most.
const BLOCK_SIZE : Int32 = 65536

///|
/// The most commands a meta-block holds: one per shortest match, and one
/// for the literals at the end.
const MAX_COMMANDS : Int32 = BLOCK_SIZE / @lz77.MIN_MATCH + 1

///|
/// The distance alphabet with NPOSTFIX and NDIRECT 0.
const DISTANCE_ALPHABET : Int32 = 64

///|
/// The commands of one meta-block, their symbol frequencies and codes.
priv struct MetaBlock {
  // Command `i` inserts `inserts[i]` literals, then copies `copies[i]`
  // bytes; `symbols[i]` is its insert-and-copy symbol. `dist_symbols[i]`
  // is its distance symbol, or -1 when none is written, with
  // `dist_extras[i]` extra bits.
  inserts : FixedArray[Int32]
  copies : FixedArray[Int32]
  symbols : FixedArray[Int32]
  dist_symbols : FixedArray[Int32]
  dist_extras : FixedArray[Int32]
  mut count : Int32
  lit_freqs : FixedArray[Int32]
  cmd_freqs : FixedArray[Int32]
  dist_freqs : FixedArray[Int32]
  lit_lengths : FixedArray[Int32]
  lit_codes : FixedArray[Int32]
  cmd_lengths : FixedArray[Int32]
  cmd_codes : FixedArray[Int32]
  dist_lengths : FixedArray[Int32]
  dist_codes : FixedArray[Int32]
  code_writer : CodeWriter
}

///|
fn MetaBlock::new() -> MetaBlock {
  {
    inserts: FixedArray::make(MAX_COMMANDS, 0),
    copies: FixedArray::make(MAX_COMMANDS, 0),
    symbols: FixedArray::make(MAX_COMMANDS, 0),
    dist_symbols: FixedArray::make(MAX_COMMANDS, 0),
    dist_extras: FixedArray::make(MAX_COMMANDS, 0),
    count: 0,
    lit_freqs: FixedArray::make(NUM_LITERALS, 0),
    cmd_freqs: FixedArray::make(MAX_ALPHABET, 0),
    dist_freqs: FixedArray::make(DISTANCE_ALPHABET, 0),
    lit_lengths: FixedArray::make(NUM_LITERALS, 0),
    lit_codes: FixedArray::make(NUM_LITERALS, 0),
    cmd_lengths: FixedArray::make(MAX_ALPHABET, 0),
    cmd_codes: FixedArray::make(MAX_ALPHABET, 0),
    dist_lengths: FixedArray::make(DISTANCE_ALPHABET, 0),
    dist_codes: FixedArray::make(DISTANCE_ALPHABET, 0),
    code_writer: CodeWriter::new(),
  }
}

///|
fn MetaBlock::clear(self : MetaBlock) -> Unit {
  self.count = 0
  self.lit_freqs.fill(0)
  self.cmd_freqs.fill(0)
  self.dist_freqs.fill(0)
}

///|
/// Adds a command. `dist_code` is a short distance code (0..3, against the
/// last distances), or -1 for an explicit `dist`, or -2 for the literals
/// that end the meta-block, which have no distance.
fn MetaBlock::push(
  self : MetaBlock,
  insert : Int32,
  copy : Int32,
  dist_code : Int32,
  dist : Int32,
) -> Unit {
  let ic = insert_code(insert)
  let cc = copy_code(copy)
  let sym = command_symbol(ic, cc, dist_code == 0 || dist_code == -2)
  let i = self.count
  self.inserts[i] = insert
  self.copies[i] = copy
  self.symbols[i] = sym
  self.cmd_freqs[sym] += 1
  if sym < 128 || dist_code == -2 {
    self.dist_symbols[i] = -1
  } else if dist_code >= 0 {
    self.dist_symbols[i] = dist_code
    self.dist_freqs[dist_code] += 1
  } else {
    let ds = distance_symbol(dist)
    self.dist_symbols[i] = ds
    self.dist_extras[i] = distance_extra(dist)
    self.dist_freqs[ds] += 1
  }
  self.count = i + 1
}

///|
/// Matches shorter than this are checked against a match one byte later.
const LAZY_LIMIT : Int32 = 32

///|
/// The longest match at `pos` in `data[..end)`, at least `MIN_MATCH`, or 0:
/// the last distance or one the matcher finds, the last distance on a tie.
/// Its distance goes to `found_dist`.
fn Encoder::longest_match(self : Encoder, pos : Int32, end : Int32) -> Int32 {
  let data = self.data
  let reach = pos.min(self.max_distance)
  let limit = end - pos
  let mut best = 0
  let last = self.dist_ring[(self.dist_ring_index - 1) & 3]
  if last <= reach && limit >= @lz77.MIN_MATCH {
    let len = @lz77.match_length(data, pos - last, pos, limit)
    if len >= @lz77.MIN_MATCH {
      best = len
      self.found_dist = last
    }
  }
  let len = self.matcher.find(data, pos, end, reach, limit)
  if len > best {
    best = len
    self.found_dist = self.matcher.distance()
  }
  best
}

///|
/// Parses `data[start..end)` into commands: at each position the longest
/// match, unless the next position has a longer one (lazy matching, as in
/// gzip). Updates the ring of last distances as the decoder will.
fn Encoder::parse(self : Encoder, start : Int32, end : Int32) -> Unit {
  let mb = self.meta_block
  mb.clear()
  let data = self.data
  let ring = self.dist_ring
  let mut pos = start
  let mut lit_start = start
  // The match at `pos` when the previous position already looked it up.
  let mut next_len = -1
  let mut next_dist = 0
  while pos < end {
    let (len, dist) = if next_len >= 0 {
      (next_len, next_dist)
    } else {
      (self.longest_match(pos, end), self.found_dist)
    }
    next_len = -1
    if len == 0 {
      mb.lit_freqs[data[pos].to_int()] += 1
      pos += 1
      continue
    }
    if len < LAZY_LIMIT && pos + 1 < end {
      let later = self.longest_match(pos + 1, end)
      if later > len {
        mb.lit_freqs[data[pos].to_int()] += 1
        pos += 1
        next_len = later
        next_dist = self.found_dist
        continue
      }
    }
    let mut code = -1
    for k in 0..<4 {
      if ring[(self.dist_ring_index - 1 - k) & 3] == dist {
        code = k
        break
      }
    }
    mb.push(pos - lit_start, len, code, dist)
    if code != 0 {
      ring[self.dist_ring_index & 3] = dist
      self.dist_ring_index += 1
    }
    pos += len
    lit_start = pos
  }
  if lit_start < end {
    mb.push(end - lit_start, 2, -2, 0)
  }
}

///|
/// The meta-block header fields MNIBBLES and MLEN - 1 (section 9.2): four
/// nibbles hold every length up to `BLOCK_SIZE`.
fn write_length(w : BitPacker, length : Int32) -> Unit {
  w.write(2, 0)
  w.write(16, length - 1)
}

///|
/// Writes `data[start..end)` as a compressed meta-block from the commands
/// `parse` made. False, part way, once it is no smaller than an
/// uncompressed meta-block; the caller rewinds the writer then.
fn Encoder::write_compressed(
  self : Encoder,
  start : Int32,
  end : Int32,
  is_last : Bool,
) -> Bool {
  let w = self.writer
  let mb = self.meta_block
  // An uncompressed meta-block takes the bytes and at most 4 header bytes.
  let budget = self.writer.position() + (end - start + 4) * 8
  w.write(1, if is_last { 1 } else { 0 })
  if is_last {
    w.write(1, 0)
  }
  write_length(w, end - start)
  if !is_last {
    w.write(1, 0)
  }
  // NBLTYPESL, NBLTYPESI and NBLTYPESD 1; NPOSTFIX and NDIRECT 0; context
  // mode LSB6; NTREESL and NTREESD 1.
  w.write(3, 0)
  w.write(6, 0)
  w.write(2, 0)
  w.write(2, 0)
  let cw = mb.code_writer
  cw.write_code(w, mb.lit_freqs, NUM_LITERALS, mb.lit_lengths, mb.lit_codes)
  cw.write_code(w, mb.cmd_freqs, MAX_ALPHABET, mb.cmd_lengths, mb.cmd_codes)
  cw.write_code(
    w,
    mb.dist_freqs,
    DISTANCE_ALPHABET,
    mb.dist_lengths,
    mb.dist_codes,
  )
  let data = self.data
  let mut pos = start
  for i in 0..<mb.count {
    if w.position() > budget {
      return false
    }
    let sym = mb.symbols[i]
    w.write(mb.cmd_lengths[sym], mb.cmd_codes[sym])
    let cell = sym >> 6
    let ic = cell_insert_base[cell] + ((sym >> 3) & 7)
    let cc = cell_copy_base[cell] + (sym & 7)
    w.write(insert_length_extra[ic], mb.inserts[i] - insert_length_base[ic])
    w.write(copy_length_extra[cc], mb.copies[i] - copy_length_base[cc])
    for p in pos..<(pos + mb.inserts[i]) {
      let b = data[p].to_int()
      w.write(mb.lit_lengths[b], mb.lit_codes[b])
      if w.position() > budget {
        return false
      }
    }
    pos += mb.inserts[i] + mb.copies[i]
    let ds = mb.dist_symbols[i]
    if ds >= 0 {
      w.write(mb.dist_lengths[ds], mb.dist_codes[ds])
      if ds >= 16 {
        w.write(distance_extra_bits(ds), mb.dist_extras[i])
      }
    }
  }
  w.position() <= budget
}

///|
/// Writes `data[start..end)` as an uncompressed meta-block, never the last.
fn Encoder::write_uncompressed(
  self : Encoder,
  start : Int32,
  end : Int32,
) -> Unit {
  let w = self.writer
  w.write(1, 0)
  write_length(w, end - start)
  w.write(1, 1)
  w.align()
  w.write_bytes(self.data, start, end - start)
}

///|
/// Encodes `data[start..end)` (1 to `BLOCK_SIZE` bytes) as a meta-block,
/// the last of the stream when `is_last`.
fn Encoder::encode_block(
  self : Encoder,
  start : Int32,
  end : Int32,
  is_last : Bool,
) -> Unit {
  let w = self.writer
  let mark = w.position()
  let mark_acc = w.acc
  let saved_ring = self.dist_ring.copy()
  let saved_index = self.dist_ring_index
  self.parse(start, end)
  if !self.write_compressed(start, end, is_last) {
    // The decoder will not see these commands' distances.
    FixedArray::unsafe_blit(self.dist_ring, 0, saved_ring, 0, 4)
    self.dist_ring_index = saved_index
    w.rewind(mark, mark_acc)
    self.write_uncompressed(start, end)
    if is_last {
      // ISLAST and ISLASTEMPTY.
      w.write(2, 3)
    }
  }
}
