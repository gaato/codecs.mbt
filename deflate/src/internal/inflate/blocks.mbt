// The blocks of RFC 1951 (section 3.2), unit by unit. Each unit asks for the
// bits zlib's inflate asks for before it decides (inflate.c), and checks
// what zlib checks in the same order, so that a stream cut short or a
// malformed one is refused with zlib's kind of error: a unit that runs out
// of input is `Truncated` with `end`, and one that has its bits is judged on
// them.

///|
/// Runs units until the input or the output runs out or the stream ends.
fn Inflater::run(
  self : Inflater,
) -> @codec_bytes.Status raise @codec.CodecError {
  for ;; {
    if self.state is Codes && self.can_go_fast() {
      self.go_fast() catch {
        Fail(kind, message) => raise @codec.CodecError(kind, message)
        NeedInput => abort("the fast path ran out of input")
      }
      continue
    }
    self.checkpoint()
    let status = self.unit() catch {
      NeedInput => {
        self.rewind()
        return NeedMoreInput
      }
      Fail(kind, message) => raise @codec.CodecError(kind, message)
    }
    if status is Some(status) {
      return status
    }
  }
}

///|
/// One unit, or several where a state loops by itself; `Some` stops the run.
fn Inflater::unit(self : Inflater) -> @codec_bytes.Status? raise Stop {
  match self.state {
    BlockHeader => self.block_header()
    StoredHeader => self.stored_header()
    Stored => return self.stored()
    TableSizes => self.table_sizes()
    CodeLengthLengths => self.code_length_length()
    CodeLengths => self.code_length()
    Codes => {
      if !self.ensure_space(MAX_MATCH) {
        return Some(NeedMoreOutput)
      }
      self.codes_unit()
    }
    Done => return Some(Done)
  }
  None
}

///|
/// BFINAL and BTYPE (zlib reads all 3 bits before it judges BTYPE).
fn Inflater::block_header(self : Inflater) -> Unit raise Stop {
  let v = self.read_bits(3)
  self.last = (v & 1) != 0
  match v >> 1 {
    0 => self.state = StoredHeader
    1 => {
      self.lit = fixed_literal_table
      self.dist = fixed_distance_table
      self.state = Codes
    }
    2 => self.state = TableSizes
    _ => raise Fail(Corrupt, "a block of the reserved type (BTYPE 3)")
  }
}

///|
/// LEN and NLEN, after the bits to the next byte boundary: all 32 bits
/// before they are compared.
fn Inflater::stored_header(self : Inflater) -> Unit raise Stop {
  self.align()
  let len = self.read_bits(16)
  let nlen = self.read_bits(16)
  if len != (nlen ^ 0xffff) {
    raise Fail(Corrupt, "a stored block's LEN and NLEN disagree")
  }
  self.stored_left = len
  self.state = Stored
}

///|
/// Copies a stored block's bytes as the input and the window allow. The bit
/// reader holds no bits here, since LEN and NLEN end on a byte boundary, and
/// no byte is kept aside: a unit that completes takes every byte kept for it,
/// which were too few for it.
fn Inflater::stored(self : Inflater) -> @codec_bytes.Status? {
  while self.stored_left > 0 {
    if !self.ensure_space(1) {
      return Some(NeedMoreOutput)
    }
    let room = (WINDOW_SIZE - self.pending).min(WINDOW_SIZE - self.wpos)
    let n = self.stored_left.min(room).min(self.view.length() - self.in_pos)
    if n == 0 {
      return Some(NeedMoreInput)
    }
    self.ring.blit_from_bytesview(
      self.wpos,
      self.view[self.in_pos:self.in_pos + n],
    )
    self.in_pos += n
    self.stored_left -= n
    self.wpos = (self.wpos + n) & WINDOW_MASK
    self.pending += n
    self.filled = (self.filled + n).min(WINDOW_SIZE)
  }
  self.end_block()
  None
}

///|
/// The end of a block: the next block's header, or after the final block the
/// end of the stream, at the next byte boundary.
fn Inflater::end_block(self : Inflater) -> Unit {
  if self.last {
    self.align()
    self.state = Done
  } else {
    self.state = BlockHeader
  }
}

///|
/// HLIT, HDIST and HCLEN: all 14 bits before the counts are judged.
fn Inflater::table_sizes(self : Inflater) -> Unit raise Stop {
  let v = self.read_bits(14)
  self.nlen = (v & 31) + 257
  self.ndist = ((v >> 5) & 31) + 1
  self.ncode = (v >> 10) + 4
  if self.nlen > 286 || self.ndist > 30 {
    raise Fail(
      Corrupt,
      "a dynamic header counts more than 286 literal/length codes or 30 distance codes",
    )
  }
  self.cl_lengths.fill(0)
  self.index = 0
  self.state = CodeLengthLengths
}

///|
/// One of the code-length code's lengths, in their order; after the last,
/// the code's table, in the distance table until the code lengths are read.
fn Inflater::code_length_length(self : Inflater) -> Unit raise Stop {
  self.cl_lengths[code_length_order[self.index]] = self.read_bits(3)
  self.index += 1
  guard self.index == self.ncode else { return }
  match shape(self.cl_lengths, 19, self.counts) {
    Complete => {
      let size = self.dist_builder.build(
        self.raw,
        0,
        self.cl_lengths,
        19,
        invalid=unused_entry,
      )
      decorate(self.raw, size, DISTANCE_ROOT_BITS, self.own_dist, CodeLength)
    }
    // No code at all: zlib reads a length of zero from each bit, and refuses
    // the block once the lengths are read, for its end-of-block code.
    Empty => self.own_dist.fill(1, end=1 << DISTANCE_ROOT_BITS)
    Lone | Bad =>
      raise Fail(
        Corrupt,
        "the code-length code is incomplete or over-subscribed",
      )
  }
  self.dist = self.own_dist
  self.index = 0
  self.prev_len = 0
  self.state = CodeLengths
}

///|
/// Sets the code length of symbol `i` of the literal/length codes and then
/// the distance codes, as one sequence.
fn Inflater::set_length(self : Inflater, i : Int32, length : Int32) -> Unit {
  if i < self.nlen {
    self.lit_lengths[i] = length
  } else {
    self.dist_lengths[i - self.nlen] = length
  }
}

///|
/// One code length, or a repeat; after the last, the block's tables.
fn Inflater::code_length(self : Inflater) -> Unit raise Stop {
  let symbol = self.read_entry(self.dist, DISTANCE_ROOT_BITS) >> 16
  let total = self.nlen + self.ndist
  if symbol < 16 {
    self.set_length(self.index, symbol)
    self.index += 1
    self.prev_len = symbol
  } else {
    let (length, count) = match symbol {
      16 => {
        let count = 3 + self.read_bits(2)
        if self.index == 0 {
          raise Fail(Corrupt, "a code-length repeat with no previous length")
        }
        (self.prev_len, count)
      }
      17 => (0, 3 + self.read_bits(3))
      _ => (0, 11 + self.read_bits(7))
    }
    if self.index + count > total {
      raise Fail(Corrupt, "a code-length repeat past the last code length")
    }
    for i in self.index..<(self.index + count) {
      self.set_length(i, length)
    }
    self.index += count
    self.prev_len = length
  }
  if self.index == total {
    self.build_tables()
  }
}

///|
/// The literal/length and distance tables of a dynamic block, once all its
/// code lengths are read: refused, as zlib refuses them, without an
/// end-of-block code, then for a literal/length code and then a distance
/// code that is over-subscribed, or incomplete and more than a lone code of
/// one bit. A distance code may have no code at all.
fn Inflater::build_tables(self : Inflater) -> Unit raise Stop {
  if self.lit_lengths[256] == 0 {
    raise Fail(Corrupt, "the literal/length code has no end-of-block code")
  }
  if shape(self.lit_lengths, self.nlen, self.counts) is Bad {
    raise Fail(
      Corrupt,
      "the literal/length code is incomplete or over-subscribed",
    )
  }
  if shape(self.dist_lengths, self.ndist, self.counts) is Bad {
    raise Fail(Corrupt, "the distance code is incomplete or over-subscribed")
  }
  let size = self.lit_builder.build(
    self.raw,
    0,
    self.lit_lengths,
    self.nlen,
    invalid=unused_entry,
  )
  decorate(self.raw, size, LITERAL_ROOT_BITS, self.own_lit, LiteralLength)
  let size = self.dist_builder.build(
    self.raw,
    0,
    self.dist_lengths,
    self.ndist,
    invalid=unused_entry,
  )
  decorate(self.raw, size, DISTANCE_ROOT_BITS, self.own_dist, Distance)
  self.lit = self.own_lit
  self.dist = self.own_dist
  self.state = Codes
}

///|
/// One literal, match or end of block, outside the fast path; the window has
/// room for a match.
fn Inflater::codes_unit(self : Inflater) -> Unit raise Stop {
  let entry = self.read_entry(self.lit, LITERAL_ROOT_BITS)
  match entry & KIND_MASK {
    KIND_LITERAL => self.put((entry >> 16).to_byte())
    KIND_BASE => {
      let length = (entry >> 16) + self.read_bits((entry >> 4) & 15)
      let d = self.read_entry(self.dist, DISTANCE_ROOT_BITS)
      if (d & KIND_MASK) != KIND_BASE {
        raise Fail(Corrupt, invalid_distance)
      }
      let distance = (d >> 16) + self.read_bits((d >> 4) & 15)
      self.copy_match(distance, length)
    }
    KIND_END_OF_BLOCK => self.end_block()
    _ => raise Fail(Corrupt, invalid_literal)
  }
}

///|
let invalid_literal : String = "an invalid literal/length code"

///|
let invalid_distance : String = "an invalid distance code"
