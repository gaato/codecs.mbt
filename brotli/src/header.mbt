// Stream and meta-block headers (RFC 7932 sections 9.1 and 9.2).

///|
fn Decoder::stream_header(self : Decoder) -> Unit raise Stop {
  // The header starts the stream, so its first byte holds all 7 bits.
  guard @rules.window_bits(self.peek_bits(7)) is Some((wbits, length)) else {
    raise corrupt("large-window streams are not RFC 7932")
  }
  self.drop_bits(length)
  if wbits > self.max_window_bits {
    let needed = window_size(wbits)
    let limit = window_size(self.max_window_bits)
    raise Fail(
      LimitExceeded({
        resource: Memory,
        needed: Some(needed.to_uint64()),
        limit: limit.to_uint64(),
      }),
      "the stream needs a \{needed}-byte window, over the limit of \{limit}",
    )
  }
  self.ring_max = 1 << wbits
  self.window = window_size(wbits)
  self.state = MetaHeader
}

///|
fn Decoder::meta_header(self : Decoder) -> Unit raise Stop {
  let is_last = self.read_bits(1) == 1
  if is_last && self.read_bits(1) == 1 {
    // ISLASTEMPTY
    self.is_last = true
    self.meta_remaining = 0
    self.state = MetaDone
    return
  }
  let nibbles = self.read_bits(2)
  if nibbles == 3 {
    // A metadata block.
    if self.read_bits(1) != 0 {
      raise corrupt("reserved bit set")
    }
    let bytes = self.read_bits(2)
    guard @rules.metadata_length(self.read_bits(8 * bytes), bytes)
      is Some(length) else {
      raise corrupt("metadata length has a needless zero byte")
    }
    self.skip_padding()
    self.is_last = is_last
    self.meta_remaining = length
    self.state = Metadata
    return
  }
  let count = nibbles + 4
  guard @rules.meta_block_length(self.read_bits(4 * count), count)
    is Some(length) else {
    raise corrupt("meta-block length has a needless zero nibble")
  }
  let uncompressed = !is_last && self.read_bits(1) == 1
  self.is_last = is_last
  self.meta_remaining = length
  if uncompressed {
    self.skip_padding()
    self.state = Uncompressed
    return
  }
  for c in 0..<3 {
    self.num_types[c] = 1
    self.block_type[c] = 0
    self.prev_block_type[c] = 1
    self.block_len[c] = ENDLESS_BLOCK
  }
  self.cat = 0
  self.state = NumBlockTypes
}

///|
/// Skips metadata bytes.
fn Decoder::metadata(self : Decoder) -> Status? raise Stop {
  while self.meta_remaining > 0 {
    if self.nbits >= 8 || self.stash_pos < self.stash.length() {
      self.next_aligned_byte() |> ignore
      self.meta_remaining -= 1
      self.checkpoint()
      continue
    }
    let n = self.meta_remaining.min(self.view.length() - self.in_pos)
    if n == 0 {
      raise NeedInput
    }
    self.in_pos += n
    self.meta_remaining -= n
    self.checkpoint()
  }
  self.state = MetaDone
  None
}

///|
/// Copies an uncompressed meta-block.
fn Decoder::uncompressed(self : Decoder) -> Status? raise Stop {
  while self.meta_remaining > 0 {
    let want = self.meta_remaining.min(1 << 16)
    if self.free_space() < want {
      self.drain()
    }
    let room = want.min(self.free_space())
    if room == 0 {
      return Some(NeedMoreOutput)
    }
    self.ensure_space(room) |> ignore
    if self.nbits >= 8 || self.stash_pos < self.stash.length() {
      self.put(self.next_aligned_byte())
      self.meta_remaining -= 1
      self.checkpoint()
      continue
    }
    let n = room.min(self.view.length() - self.in_pos)
    if n == 0 {
      raise NeedInput
    }
    self.copy_input(n)
    self.meta_remaining -= n
    self.checkpoint()
  }
  self.state = MetaDone
  None
}

///|
fn Decoder::num_block_types(self : Decoder) -> Unit raise Stop {
  let n = self.read_var_len8() + 1
  self.num_types[self.cat] = n
  if n >= 2 {
    self.type_codes[self.cat].reset(1, n + 2)
    self.count_codes[self.cat].reset(1, @rules.NUM_BLOCK_COUNT_CODES)
    self.code.start(n + 2, self.type_codes[self.cat], 0)
    self.state = BlockTypeCode
  } else {
    self.next_category()
  }
}

///|
/// A block count: a symbol of category `cat`'s count code and extra bits.
fn Decoder::read_block_count(self : Decoder, cat : Int32) -> Int32 raise Stop {
  let code = self.read_symbol(self.count_codes[cat], 0)
  @rules.block_count(code, self.read_bits(@rules.block_count_extra_bits(code)))
}

///|
fn Decoder::next_category(self : Decoder) -> Unit {
  self.cat += 1
  self.state = if self.cat < 3 { NumBlockTypes } else { DistanceParams }
}

///|
fn Decoder::distance_params(self : Decoder) -> Unit raise Stop {
  let npostfix = self.read_bits(2)
  let ndirect = @rules.direct_distance_codes(npostfix, self.read_bits(4))
  self.npostfix = npostfix
  self.ndirect = ndirect
  self.index = 0
  self.state = ContextModes
}

///|
fn Decoder::context_mode(self : Decoder) -> Unit raise Stop {
  self.context_modes[self.index] = self.read_bits(2)
  self.index += 1
  if self.index == self.num_types[0] {
    self.cat = 0
    self.state = NumTrees
  }
}

///|
/// NTREESL (`cat` 0) or NTREESD (`cat` 2).
fn Decoder::num_trees(self : Decoder) -> Unit raise Stop {
  let trees = self.read_var_len8() + 1
  let (map, size) = if self.cat == 0 {
    self.lit_trees_count = trees
    (self.lit_context_map, 64 * self.num_types[0])
  } else {
    self.dist_trees_count = trees
    (self.dist_context_map, 4 * self.num_types[2])
  }
  self.map_size = size
  if trees >= 2 {
    self.state = ContextMapHeader
  } else {
    map.fill(b'\x00', end=size)
    self.after_context_map()
  }
}

///|
fn Decoder::context_map_header(self : Decoder) -> Unit raise Stop {
  let rle_max = if self.read_bits(1) == 1 { self.read_bits(4) + 1 } else { 0 }
  let trees = if self.cat == 0 {
    self.lit_trees_count
  } else {
    self.dist_trees_count
  }
  self.map_rle_max = rle_max
  self.index = 0
  self.map_code.reset(1, trees + rle_max)
  self.code.start(trees + rle_max, self.map_code, 0)
  self.state = ContextMapCode
}

///|
fn Decoder::context_map_entry(self : Decoder) -> Unit raise Stop {
  let map = if self.cat == 0 {
    self.lit_context_map
  } else {
    self.dist_context_map
  }
  let sym = self.read_symbol(self.map_code, 0)
  if sym == 0 {
    map[self.index] = b'\x00'
    self.index += 1
  } else if sym <= self.map_rle_max {
    let run = (1 << sym) + self.read_bits(sym)
    if self.index + run > self.map_size {
      raise corrupt("context map run past its end")
    }
    map.fill(b'\x00', start=self.index, end=self.index + run)
    self.index += run
  } else {
    map[self.index] = (sym - self.map_rle_max).to_byte()
    self.index += 1
  }
  if self.index == self.map_size {
    self.state = ContextMapImtf
  }
}

///|
fn Decoder::context_map_imtf(self : Decoder) -> Unit raise Stop {
  if self.read_bits(1) == 1 {
    let map = if self.cat == 0 {
      self.lit_context_map
    } else {
      self.dist_context_map
    }
    @rules.inverse_move_to_front(map, self.map_size)
  }
  self.after_context_map()
}

///|
fn Decoder::after_context_map(self : Decoder) -> Unit {
  if self.cat == 0 {
    self.cat = 2
    self.state = NumTrees
  } else {
    self.cat = 0
    self.start_trees()
  }
}

///|
/// The group of trees of category `cat`, its tree count and alphabet.
fn Decoder::trees(self : Decoder, cat : Int32) -> (Group, Int32, Int32) {
  match cat {
    0 => (self.lit_trees, self.lit_trees_count, NUM_LITERALS)
    1 => (self.cmd_trees, self.num_types[1], MAX_ALPHABET)
    _ =>
      (
        self.dist_trees,
        self.dist_trees_count,
        @rules.distance_alphabet_size(self.npostfix, self.ndirect),
      )
  }
}

///|
/// Starts reading the trees of category `cat`.
fn Decoder::start_trees(self : Decoder) -> Unit {
  let (group, count, alphabet) = self.trees(self.cat)
  group.reset(count, alphabet)
  self.index = 0
  self.code.start(alphabet, group, 0)
  self.state = TreeCodes
}

///|
fn Decoder::tree_code(self : Decoder) -> Unit raise Stop {
  guard self.read_code() else { return }
  let (group, count, alphabet) = self.trees(self.cat)
  self.index += 1
  if self.index < count {
    self.code.start(alphabet, group, self.index)
  } else if self.cat < 2 {
    self.cat += 1
    self.start_trees()
  } else {
    self.lit_mode = self.context_modes[0]
    self.lit_map_offset = 0
    self.dist_map_offset = 0
    self.state = CommandStart
  }
}
