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
/// The literals of a command.
fn Decoder::literals(self : Decoder) -> Status? raise Stop {
  let trees = self.lit_trees
  let map = self.lit_context_map
  while self.insert_remaining > 0 {
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
