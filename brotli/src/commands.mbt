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
    self.fast_commands()
    // `run` goes on from where the fast loop stopped, in its own state; a
    // command here starts after what the fast loop decoded.
    guard self.state is CommandStart else { return None }
    self.checkpoint()
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
/// Bytes of input that hold a whole command's bits however the bit reader
/// stands: a symbol and two extra fields, each read after a refill of at
/// most three bytes.
const FAST_COMMAND_INPUT : Int32 = 9

///|
/// Bytes of input that hold a distance's symbol and extra bits.
const FAST_DISTANCE_INPUT : Int32 = 6

///|
/// Commands one after another, through their literals, distances and
/// copies, while the input surely holds the bits of the next part: with the
/// stash empty, a refill then always finds its bytes in `view`, so no read
/// runs short and none of the checkpoints and raises of `command`,
/// `distance` and `read_symbol` is needed. Each part reads the bits that
/// part reads, refilling where it refills, so that the bytes taken from the
/// input are the same. Anything else, an error, a dictionary word, a block
/// switch, the end of the meta-block or the room running out, leaves the
/// part unread, its bit reader as it was, for the slow path, which then
/// meets it as it would have; so does a literal that `fast_literals` does
/// not decode. Returns in the state the slow path would reach there.
fn Decoder::fast_commands(self : Decoder) -> Unit {
  guard fast_commands_pay() && self.stash_pos >= self.stash.length() else {
    return
  }
  let view = self.view
  let len = view.length()
  guard len - self.in_pos >= FAST_COMMAND_INPUT else { return }
  let cmd_pool = self.cmd_trees.pool
  let cmd_offsets = self.cmd_trees.offsets
  let dist_pool = self.dist_trees.pool
  let dist_offsets = self.dist_trees.offsets
  let mut acc = self.acc
  let mut nbits = self.nbits
  let mut in_pos = self.in_pos
  while self.state is CommandStart {
    // The three block categories use slot 1 for commands and 2 for distances.
    guard len - in_pos >= FAST_COMMAND_INPUT && self.block_len.unsafe_get(1) > 0 else {
      break
    }
    let saved_acc = acc
    let saved_nbits = nbits
    let saved_in_pos = in_pos
    if nbits < MAX_CODE_LENGTH {
      while nbits <= 23 {
        // The command guard reserves three bytes for each of three refills.
        acc = acc | (view.unsafe_get(in_pos).to_int() << nbits)
        in_pos += 1
        nbits += 8
      }
    }
    // The active command block type selects one of its built trees.
    let base = cmd_offsets.unsafe_get(self.block_type.unsafe_get(1))
    // The root mask and the subtable mask index entries laid out by Group::build.
    let mut entry = cmd_pool.unsafe_get(base + (acc & (ROOT_SIZE - 1))).to_int()
    let mut bits = entry & 15
    if bits > ROOT_BITS {
      let sub = (acc >> ROOT_BITS) & ((1 << (bits - ROOT_BITS)) - 1)
      entry = cmd_pool.unsafe_get(base + (entry >> 4) + sub).to_int()
      bits = entry & 15
    }
    acc = acc >> bits
    nbits -= bits
    let sym = entry >> 4
    // Command symbols are below 704, giving one of the 11 cells. The
    // cell bases are 0, 8 or 16, and the low code bits add at most 7.
    let cell = sym >> 6
    let insert_code = cell_insert_base.unsafe_get(cell) + ((sym >> 3) & 7)
    let copy_code = cell_copy_base.unsafe_get(cell) + (sym & 7)
    let insert_bits = insert_length_extra.unsafe_get(insert_code)
    if nbits < insert_bits {
      while nbits <= 23 {
        // At most three of the command guard's nine bytes were used above.
        acc = acc | (view.unsafe_get(in_pos).to_int() << nbits)
        in_pos += 1
        nbits += 8
      }
    }
    let insert_len = insert_length_base.unsafe_get(insert_code) +
      (acc & ((1 << insert_bits) - 1))
    acc = acc >> insert_bits
    nbits -= insert_bits
    let copy_bits = copy_length_extra.unsafe_get(copy_code)
    if nbits < copy_bits {
      while nbits <= 23 {
        // At most six of the command guard's nine bytes were used above.
        acc = acc | (view.unsafe_get(in_pos).to_int() << nbits)
        in_pos += 1
        nbits += 8
      }
    }
    let copy_len = copy_length_base.unsafe_get(copy_code) +
      (acc & ((1 << copy_bits) - 1))
    acc = acc >> copy_bits
    nbits -= copy_bits
    if insert_len > self.meta_remaining {
      acc = saved_acc
      nbits = saved_nbits
      in_pos = saved_in_pos
      break
    }
    self.block_len.unsafe_set(1, self.block_len.unsafe_get(1) - 1)
    self.meta_remaining -= insert_len
    self.insert_remaining = insert_len
    self.copy_len = copy_len
    self.implicit_distance = sym < 128
    self.state = Literals
    if insert_len > 0 {
      self.acc = acc
      self.nbits = nbits
      self.in_pos = in_pos
      while self.insert_remaining > 0 && self.fast_literals() > 0 {

      }
      acc = self.acc
      nbits = self.nbits
      in_pos = self.in_pos
      guard self.insert_remaining == 0 else { break }
    }
    // As `literals` ends: a command that fills the meta-block has no
    // distance.
    if self.meta_remaining == 0 {
      self.state = MetaDone
      break
    }
    self.state = Distance
    // As `distance` begins, where `ensure_space` would find the room
    // without draining or growing the window.
    let cap = self.ring.length()
    let room = if cap == self.ring_max {
      cap - self.pending
    } else {
      cap - self.wpos
    }
    guard room >= MAX_TRANSFORMED_WORD else { break }
    let saved_acc = acc
    let saved_nbits = nbits
    let saved_in_pos = in_pos
    let mut code = 0
    let mut extra = 0
    if !self.implicit_distance {
      guard len - in_pos >= FAST_DISTANCE_INPUT &&
        self.block_len.unsafe_get(2) > 0 else {
        break
      }
      let context = (self.copy_len - 2).min(3)
      // The map holds four entries per distance block type. Copy lengths
      // are at least 2.
      let tree = self.dist_context_map
        .unsafe_get(self.dist_map_offset + context)
        .to_int()
      if nbits < MAX_CODE_LENGTH {
        while nbits <= 23 {
          // The distance guard reserves three bytes for each of two refills.
          acc = acc | (view.unsafe_get(in_pos).to_int() << nbits)
          in_pos += 1
          nbits += 8
        }
      }
      // The map entry is a byte and dist_offsets holds 256 entries.
      let base = dist_offsets.unsafe_get(tree)
      // The root mask and the subtable mask index entries laid out by Group::build.
      let mut entry = dist_pool
        .unsafe_get(base + (acc & (ROOT_SIZE - 1)))
        .to_int()
      let mut bits = entry & 15
      if bits > ROOT_BITS {
        let sub = (acc >> ROOT_BITS) & ((1 << (bits - ROOT_BITS)) - 1)
        entry = dist_pool.unsafe_get(base + (entry >> 4) + sub).to_int()
        bits = entry & 15
      }
      acc = acc >> bits
      nbits -= bits
      code = entry >> 4
      let n = @rules.distance_extra_bits(code, self.npostfix, self.ndirect)
      if nbits < n {
        while nbits <= 23 {
          // At most three of the distance guard's six bytes were used above.
          acc = acc | (view.unsafe_get(in_pos).to_int() << nbits)
          in_pos += 1
          nbits += 8
        }
      }
      extra = acc & ((1 << n) - 1)
      acc = acc >> n
      nbits -= n
    }
    // Masking by 3 keeps every distance index in the four-entry ring.
    let dist = @rules.distance(
      code,
      extra,
      npostfix=self.npostfix,
      ndirect=self.ndirect,
      last1=self.dist_ring.unsafe_get((self.dist_ring_index - 1) & 3),
      last2=self.dist_ring.unsafe_get((self.dist_ring_index - 2) & 3),
      last3=self.dist_ring.unsafe_get((self.dist_ring_index - 3) & 3),
      last4=self.dist_ring.unsafe_get((self.dist_ring_index - 4) & 3),
    )
    guard dist is Some(dist) &&
      dist <= self.filled &&
      self.copy_len <= self.meta_remaining else {
      acc = saved_acc
      nbits = saved_nbits
      in_pos = saved_in_pos
      break
    }
    if !self.implicit_distance {
      self.block_len.unsafe_set(2, self.block_len.unsafe_get(2) - 1)
    }
    if code != 0 {
      self.dist_ring.unsafe_set(self.dist_ring_index & 3, dist)
      self.dist_ring_index += 1
    }
    let n = self.copy_len
    self.meta_remaining -= n
    self.copy_remaining = n
    self.copy_dist = dist
    self.state = Copy
    // The same room and wrap checks as copy_fast. Leave Copy pending if
    // the slow path must drain, grow or wrap the ring first.
    let ring = self.ring
    let dst = self.wpos
    let src = dst - dist
    guard n <= room && src >= 0 && dst + n <= cap else { break }
    if dist >= n {
      @blit.bytes(ring, dst, ring, src, n)
    } else {
      @blit.forward(ring, dst, src, n)
    }
    let wpos = dst + n
    self.wpos = if wpos == self.ring_max { 0 } else { wpos }
    self.pending += n
    self.filled = (self.filled + n).min(self.window)
    self.copy_remaining = 0
    self.state = if self.meta_remaining == 0 { MetaDone } else { CommandStart }
  }
  self.acc = acc
  self.nbits = nbits
  self.in_pos = in_pos
}

///|
/// Whether `fast_commands` runs. On an i5-10400F (2026-11-19), the Wasm
/// whole-text decode went from 8.15 to 3.64 ms in `compare_speed_brotli`
/// and from 8.38 to 3.57 ms in the combined `compare_speed` binary.
fn fast_commands_pay() -> Bool {
  true
}

///|
// command supplies a block category or a code bounded by its alphabet.
#cfg(target="wasm")
#inline
fn command_value(table : FixedArray[Int32], index : Int32) -> Int32 {
  table.unsafe_get(index)
}

///|
#cfg(not(target="wasm"))
#inline
fn command_value(table : FixedArray[Int32], index : Int32) -> Int32 {
  table[index]
}

///|
/// An insert-and-copy command.
fn Decoder::command(self : Decoder) -> Unit raise Stop {
  // Commands are slot 1 of the three block categories.
  let remaining = command_value(self.block_len, 1)
  if remaining == 0 {
    self.switch_block(1)
    return
  }
  let sym = self.read_symbol(self.cmd_trees, command_value(self.block_type, 1))
  // A command symbol is below 704, so cell < 11. The bases are 0, 8 or
  // 16 and the low bits add at most 7, within the 24 length codes.
  let cell = sym >> 6
  let insert_code = command_value(cell_insert_base, cell) + ((sym >> 3) & 7)
  let copy_code = command_value(cell_copy_base, cell) + (sym & 7)
  let insert_len = command_value(insert_length_base, insert_code) +
    self.read_bits(command_value(insert_length_extra, insert_code))
  let copy_len = command_value(copy_length_base, copy_code) +
    self.read_bits(command_value(copy_length_extra, copy_code))
  if INLINE_SLOW_LITERAL {
    // Slot 1 is the command category in the three-entry table.
    self.block_len.unsafe_set(1, remaining - 1)
  } else {
    self.block_len[1] -= 1
  }
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
    // `offsets` holds 256 trees and a map entry is a byte; the entries are
    // within the tree's table, as `Group::build` lays it out.
    let base = offsets.unsafe_get(map.unsafe_get(map_offset + context).to_int())
    let mut entry = pool.unsafe_get(base + (acc & (ROOT_SIZE - 1))).to_int()
    let mut bits = entry & 15
    if bits > ROOT_BITS {
      let sub = (acc >> ROOT_BITS) & ((1 << (bits - ROOT_BITS)) - 1)
      entry = pool.unsafe_get(base + (entry >> 4) + sub).to_int()
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
    @blit.forward(ring, dst, src, n)
  }
  self.advance(n)
  self.copy_remaining = 0
}

///|
// Wasm still calls read_symbol out of line in this loop.
#cfg(target="wasm")
const INLINE_SLOW_LITERAL : Bool = true

///|
#cfg(not(target="wasm"))
const INLINE_SLOW_LITERAL : Bool = false

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
    let b = if INLINE_SLOW_LITERAL {
      let ring = self.ring
      let mask = ring.length() - 1
      // ensure_space made a nonempty, power-of-two ring.
      let p1 = ring.unsafe_get((self.wpos - 1) & mask).to_int()
      let p2 = ring.unsafe_get((self.wpos - 2) & mask).to_int()
      // The previous bytes fit the LUTs. Context is below 64 and the map
      // has 64 entries per block type. A byte indexes the 256 offsets.
      let context = match self.lit_mode {
        0 => p1 & 0x3f
        1 => p1 >> 2
        2 => lut0.unsafe_get(p1).to_int() | lut1.unsafe_get(p2).to_int()
        _ => (lut2.unsafe_get(p1).to_int() << 3) | lut2.unsafe_get(p2).to_int()
      }
      let tree = map.unsafe_get(self.lit_map_offset + context).to_int()
      let base = trees.offsets.unsafe_get(tree)
      if self.nbits < MAX_CODE_LENGTH {
        self.refill()
      }
      let acc = self.acc
      // Root and subtable masks stay within the tree built by Group::build.
      let pool = trees.pool
      let mut entry = pool.unsafe_get(base + (acc & (ROOT_SIZE - 1))).to_int()
      let mut bits = entry & 15
      if bits > ROOT_BITS {
        let sub = (acc >> ROOT_BITS) & ((1 << (bits - ROOT_BITS)) - 1)
        entry = pool.unsafe_get(base + (entry >> 4) + sub).to_int()
        bits = entry & 15
      }
      if bits > self.nbits {
        raise NeedInput
      }
      self.acc = acc >> bits
      self.nbits -= bits
      entry >> 4
    } else {
      let context = literal_context(
        self.lit_mode,
        self.last_byte(1),
        self.last_byte(2),
      )
      self.read_symbol(trees, map[self.lit_map_offset + context].to_int())
    }
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
  let dict_len = match self.dictionary {
    Some(d) => d.content.length()
    None => 0
  }
  let address = lz77_address(dist, self.filled, dict_len, self.copy_len)
  if address >= 0 {
    if code != 0 {
      self.dist_ring[self.dist_ring_index & 3] = dist
      self.dist_ring_index += 1
    }
    if self.copy_len > self.meta_remaining {
      raise corrupt("copy past the end of the meta-block")
    }
    self.meta_remaining -= self.copy_len
    self.copy_remaining = self.copy_len
    self.dict_at = address
    self.state = DictionaryCopy
    return None
  }
  self.dictionary_word(dist - dict_len)
  self.state = if self.meta_remaining == 0 { MetaDone } else { CommandStart }
  None
}

///|
/// Where a copy of `copy_len` bytes from `dist` back starts in an LZ77
/// dictionary of `dict_len` bytes (RFC 9841 section 3.2), when `dist` is
/// past the window's reach, `filled`: the dictionary's address, counted
/// from its start, for a distance at most `dict_len` past the reach, or -1
/// for one further, which names a static dictionary word. A copy that would
/// run past the dictionary's end is refused, as the reference decoder
/// refuses it: RFC 9841 has it go on from the window's beginning, which a
/// full window no longer holds.
fn lz77_address(
  dist : Int32,
  filled : Int32,
  dict_len : Int32,
  copy_len : Int32,
) -> Int32 raise Stop {
  let past = dist - filled
  if past > dict_len {
    return -1
  }
  let address = dict_len - past
  if copy_len > past {
    raise corrupt("a copy past the end of the LZ77 dictionary")
  }
  address
}

///|
/// The distance `k` (1 to 4) places back in the ring of last distances.
fn Decoder::last_distance(self : Decoder, k : Int32) -> Int32 {
  self.dist_ring[(self.dist_ring_index - k) & 3]
}

///|
/// Writes the static dictionary word distance `dist` names (section 8), past
/// any LZ77 dictionary.
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
