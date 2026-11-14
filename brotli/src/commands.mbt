// Compressed meta-block data (RFC 7932 sections 4 to 9.3): commands,
// literals, distances, backward copies and dictionary references.

///|
/// A block switch command of category `cat` (section 6).
fn Decoder::switch_block(self : Decoder, cat : Int32) -> Unit raise Stop {
  let sym = self.read_symbol(self.type_codes[cat], 0)
  let len = self.read_block_count(cat)
  let t = @rules.next_block_type(
    sym,
    current=self.block_type[cat],
    previous=self.prev_block_type[cat],
    types=self.num_types[cat],
  )
  self.prev_block_type[cat] = self.block_type[cat]
  self.block_type[cat] = t
  self.block_len[cat] = len
  if cat == 0 {
    self.lit_mode = self.context_modes[t]
    self.lit_map_offset = t * 64
  } else if cat == 2 {
    self.dist_map_offset = t * 4
  }
}

///|
/// Commands one after another, each through its literals, distance and
/// copy, without going back to `run` between them. Each step checkpoints
/// where `run` would: before a command here, and `literals` and `distance`
/// before what they read, so that running out of input rewinds to the same
/// place. Stops, for `run` to go on, where a state does not lead to the
/// next as a command does (a block switch, the end of the meta-block), and
/// when output runs out.
fn Decoder::commands(self : Decoder) -> Status? raise Stop {
  for ;; {
    self.command()
    guard self.state is Literals else { return None }
    if self.literals() is Some(status) {
      return Some(status)
    }
    guard self.state is Distance else { return None }
    if self.distance() is Some(status) {
      return Some(status)
    }
    guard self.state is Copy else { return None }
    if self.copy() is Some(status) {
      return Some(status)
    }
    guard self.state is CommandStart else { return None }
    self.checkpoint()
  }
}

///|
/// An insert-and-copy command.
fn Decoder::command(self : Decoder) -> Unit raise Stop {
  if self.block_len[1] == 0 {
    self.switch_block(1)
    return
  }
  let sym = self.read_symbol(self.cmd_trees, self.block_type[1])
  let cell = sym >> 6
  let insert_code = cell_insert_base[cell] + ((sym >> 3) & 7)
  let copy_code = cell_copy_base[cell] + (sym & 7)
  let insert_len = insert_length_base[insert_code] +
    self.read_bits(insert_length_extra[insert_code])
  let copy_len = copy_length_base[copy_code] +
    self.read_bits(copy_length_extra[copy_code])
  self.block_len[1] -= 1
  if insert_len > self.meta_remaining {
    raise corrupt("insert past the end of the meta-block")
  }
  self.meta_remaining -= insert_len
  self.insert_remaining = insert_len
  self.copy_len = copy_len
  self.implicit_distance = sym < 128
  self.state = Literals
}

///|
/// Decodes as many of the command's literals as can be had in one go: in
/// the current block, without new input or room. With the stash empty it
/// reads only from `view`, and only while three bytes are left, so a
/// literal (at most 15 bits) never waits for input; and it
/// writes no more than `ensure_space` would allow without handing out or
/// growing the window. So none of the checks and checkpoints of `literals`
/// is needed, and the read state stays in locals. Returns how many literals
/// it decoded: 0 when the stash holds bytes, the block or the room is used
/// up, or the input is short, which `literals` then deals with.
fn Decoder::fast_literals(self : Decoder) -> Int32 {
  guard self.stash_pos >= self.stash.length() else { return 0 }
  let ring = self.ring
  let cap = ring.length()
  let room = if cap == self.ring_max {
    cap - self.pending
  } else {
    cap - self.wpos
  }
  let n = self.insert_remaining.min(self.block_len[0]).min(room)
  guard n > 0 else { return 0 }
  let view = self.view
  let len = view.length()
  let group = self.lit_trees
  let pool = group.pool
  let offsets = group.offsets
  let map = self.lit_context_map
  let map_offset = self.lit_map_offset
  let mode = self.lit_mode
  let ring_max = self.ring_max
  // The ring's size is a power of two, as `last_byte` takes it.
  let mask = cap - 1
  let mut acc = self.acc
  let mut nbits = self.nbits
  let mut in_pos = self.in_pos
  let mut wpos = self.wpos
  let mut p1 = ring[(wpos - 1) & mask].to_int()
  let mut p2 = ring[(wpos - 2) & mask].to_int()
  let mut k = 0
  while k < n {
    if nbits < MAX_CODE_LENGTH {
      // As `read_symbol` refills: whole bytes until more than 23 bits are
      // held, two or three of them, so that the bytes taken from the input
      // are the same as on the slow path. in_pos + 2 < len.
      guard len - in_pos >= 3 else { break }
      acc = acc |
        (view.unsafe_get(in_pos).to_int() << nbits) |
        (view.unsafe_get(in_pos + 1).to_int() << (nbits + 8))
      in_pos += 2
      nbits += 16
      if nbits <= 23 {
        acc = acc | (view.unsafe_get(in_pos).to_int() << nbits)
        in_pos += 1
        nbits += 8
      }
    }
    // `literal_context`, written out: context < 64, and the map holds 64
    // entries for each block type; p1 and p2 are bytes, within the tables.
    let context = match mode {
      0 => p1 & 0x3f
      1 => p1 >> 2
      2 => lut0.unsafe_get(p1).to_int() | lut1.unsafe_get(p2).to_int()
      _ => (lut2.unsafe_get(p1).to_int() << 3) | lut2.unsafe_get(p2).to_int()
    }
    let base = offsets[map.unsafe_get(map_offset + context).to_int()]
    let mut entry = pool[base + (acc & (ROOT_SIZE - 1))].to_int()
    let mut bits = entry & 15
    if bits > ROOT_BITS {
      let sub = (acc >> ROOT_BITS) & ((1 << (bits - ROOT_BITS)) - 1)
      entry = pool[base + (entry >> 4) + sub].to_int()
      bits = entry & 15
    }
    acc = acc >> bits
    nbits -= bits
    let b = entry >> 4
    // wpos < cap, and the room says it holds no pending output.
    ring.unsafe_set(wpos, b.to_byte())
    wpos += 1
    if wpos == ring_max {
      wpos = 0
    }
    p2 = p1
    p1 = b
    k += 1
  }
  self.acc = acc
  self.nbits = nbits
  self.in_pos = in_pos
  self.wpos = wpos
  self.pending += k
  self.filled = (self.filled + k).min(self.window)
  self.block_len[0] -= k
  self.insert_remaining -= k
  k
}

///|
/// The copy of a command when it fits as it is: room for it without
/// handing out or growing the window, and neither its source nor its
/// destination wrapping around the ring. Leaves `copy_remaining` as it is
/// otherwise, for `copy`.
fn Decoder::copy_fast(self : Decoder) -> Unit {
  let n = self.copy_remaining
  let dist = self.copy_dist
  let ring = self.ring
  let cap = ring.length()
  let dst = self.wpos
  let src = dst - dist
  let room = if cap == self.ring_max { cap - self.pending } else { cap - dst }
  guard n <= room && src >= 0 && dst + n <= cap else { return }
  // dist <= filled: src..src + n and dst..dst + n are within the ring.
  if dist >= n {
    @blit.bytes(ring, dst, ring, src, n)
  } else {
    copy_overlapping(ring, dst, src, n)
  }
  self.advance(n)
  self.copy_remaining = 0
}

///|
/// The literals of a command.
fn Decoder::literals(self : Decoder) -> Status? raise Stop {
  let trees = self.lit_trees
  let map = self.lit_context_map
  while self.insert_remaining > 0 {
    if self.fast_literals() > 0 {
      continue
    }
    if !self.ensure_space(1) {
      return Some(NeedMoreOutput)
    }
    self.checkpoint()
    if self.block_len[0] == 0 {
      self.switch_block(0)
      continue
    }
    let context = literal_context(
      self.lit_mode,
      self.last_byte(1),
      self.last_byte(2),
    )
    let b = self.read_symbol(trees, map[self.lit_map_offset + context].to_int())
    self.put(b.to_byte())
    self.block_len[0] -= 1
    self.insert_remaining -= 1
  }
  // A command that fills the meta-block has no distance.
  self.state = if self.meta_remaining == 0 { MetaDone } else { Distance }
  None
}

///|
/// The distance of a command and the copy or dictionary word it names.
fn Decoder::distance(self : Decoder) -> Status? raise Stop {
  if !self.ensure_space(MAX_TRANSFORMED_WORD) {
    return Some(NeedMoreOutput)
  }
  self.checkpoint()
  let mut code = 0
  let mut extra = 0
  if !self.implicit_distance {
    if self.block_len[2] == 0 {
      self.switch_block(2)
      return None
    }
    let context = (self.copy_len - 2).min(3)
    let tree = self.dist_context_map[self.dist_map_offset + context].to_int()
    code = self.read_symbol(self.dist_trees, tree)
    // Keep the extra bits with the code: decode both before committing.
    extra = self.read_bits(
      @rules.distance_extra_bits(code, self.npostfix, self.ndirect),
    )
    self.block_len[2] -= 1
  }
  guard @rules.distance(
      code,
      extra,
      npostfix=self.npostfix,
      ndirect=self.ndirect,
      last1=self.last_distance(1),
      last2=self.last_distance(2),
      last3=self.last_distance(3),
      last4=self.last_distance(4),
    )
    is Some(dist) else {
    raise corrupt("distance below one")
  }
  if dist <= self.filled {
    if code != 0 {
      self.dist_ring[self.dist_ring_index & 3] = dist
      self.dist_ring_index += 1
    }
    if self.copy_len > self.meta_remaining {
      raise corrupt("copy past the end of the meta-block")
    }
    self.meta_remaining -= self.copy_len
    self.copy_remaining = self.copy_len
    self.copy_dist = dist
    self.state = Copy
    return None
  }
  self.dictionary_word(dist)
  self.state = if self.meta_remaining == 0 { MetaDone } else { CommandStart }
  None
}

///|
/// The distance `k` (1 to 4) places back in the ring of last distances.
fn Decoder::last_distance(self : Decoder, k : Int32) -> Int32 {
  self.dist_ring[(self.dist_ring_index - k) & 3]
}

///|
/// Writes the static dictionary word distance `dist` names (section 8).
fn Decoder::dictionary_word(self : Decoder, dist : Int32) -> Unit raise Stop {
  let length = self.copy_len
  if length < 4 || length > 24 {
    raise corrupt("distance beyond the window with no dictionary word")
  }
  let word_id = dist - self.filled - 1
  let bits = dictionary_size_bits[length]
  let transform = word_id >> bits
  if transform >= NUM_TRANSFORMS {
    raise corrupt("distance beyond the window and the dictionary")
  }
  let n = transform_word(
    self.word,
    length,
    word_id & ((1 << bits) - 1),
    transform,
  )
  if n > self.meta_remaining {
    raise corrupt("dictionary word past the end of the meta-block")
  }
  for i in 0..<n {
    self.put(self.word[i])
  }
  self.meta_remaining -= n
}

///|
/// The bytes of a backward copy, as far as the output allows.
fn Decoder::copy(self : Decoder) -> Status? {
  self.copy_fast()
  while self.copy_remaining > 0 {
    let want = self.copy_remaining.min(1 << 16)
    if self.free_space() < want {
      self.drain()
    }
    let n = want.min(self.free_space())
    if n == 0 {
      return Some(NeedMoreOutput)
    }
    self.ensure_space(n) |> ignore
    self.copy_back(self.copy_dist, n)
    self.copy_remaining -= n
  }
  self.state = if self.meta_remaining == 0 { MetaDone } else { CommandStart }
  None
}

///|
/// Copies `n` bytes from `src` to `dst` in `ring`, `src < dst`, going
/// forward so that a byte written may be read again: a match whose
/// distance `dst - src` is shorter than it. The caller has checked that
/// `dst + n` is within `ring`. Eight bytes at a time when the distance
/// allows, on the targets that have eight-byte loads.
#cfg(any(target="native", target="wasm"))
fn copy_overlapping(
  ring : FixedArray[Byte],
  dst : Int32,
  src : Int32,
  n : Int32,
) -> Unit {
  let mut i = 0
  if dst - src >= 8 {
    let bytes = ring.unsafe_reinterpret_as_bytes()
    // Each eight bytes read lie before the eight written, within the ring.
    while i + 8 <= n {
      ring.unsafe_write_uint64_le(dst + i, bytes.unsafe_read_uint64_le(src + i))
      i += 8
    }
  }
  while i < n {
    ring.unsafe_set(dst + i, ring.unsafe_get(src + i))
    i += 1
  }
}

///|
#cfg(not(any(target="native", target="wasm")))
fn copy_overlapping(
  ring : FixedArray[Byte],
  dst : Int32,
  src : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    ring.unsafe_set(dst + i, ring.unsafe_get(src + i))
  }
}
