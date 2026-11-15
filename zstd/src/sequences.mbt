// The sequences section of a compressed block (RFC 8878 section
// 3.1.1.3.2) and sequence execution (section 3.1.1.4). Sequences are
// executed as they are decoded, straight into the window.

///|
/// Decodes the compressed block in `block[0:block_size]` into the window.
/// No output is pending, so the block's at most `block_max` bytes fit.
fn Decoder::decode_block(self : Decoder) -> Unit raise Stop {
  let size = self.block_size
  let start = self.decode_literals(size)
  if start >= size {
    raise corrupt("a compressed block without its sequences section")
  }
  let block = self.block
  let b0 = block[start].to_int()
  let (count, header_end) = if b0 < 128 {
    (b0, start + 1)
  } else if b0 < 255 {
    if start + 2 > size {
      raise corrupt("a sequences header past its block")
    }
    (((b0 - 128) << 8) + block[start + 1].to_int(), start + 2)
  } else {
    if start + 3 > size {
      raise corrupt("a sequences header past its block")
    }
    (
      block[start + 1].to_int() + (block[start + 2].to_int() << 8) + 0x7F00,
      start + 3,
    )
  }
  let mut at = header_end
  if count == 0 {
    if at != size {
      raise corrupt("bytes after a sequences section without sequences")
    }
    self.put_literals(0, self.literals_len)
    return
  }
  if at >= size {
    raise corrupt("a sequences header past its block")
  }
  let modes = block[at].to_int()
  at += 1
  if (modes & 3) != 0 {
    raise corrupt("the sequences header's reserved bits are set")
  }
  let ll = self.sequence_table(
    (modes >> 6) & 3,
    self.ll_table,
    self.ll_store,
    ll_predefined,
    at,
    9,
    MAX_LL_CODE,
    "literals lengths",
  )
  self.ll_table = Some(ll.0)
  at += ll.1
  let of = self.sequence_table(
    (modes >> 4) & 3,
    self.of_table,
    self.of_store,
    of_predefined,
    at,
    8,
    MAX_OF_SYMBOL,
    "offsets",
  )
  self.of_table = Some(of.0)
  at += of.1
  let ml = self.sequence_table(
    (modes >> 2) & 3,
    self.ml_table,
    self.ml_store,
    ml_predefined,
    at,
    9,
    MAX_ML_CODE,
    "match lengths",
  )
  self.ml_table = Some(ml.0)
  at += ml.1
  self.execute(ll.0, of.0, ml.0, at, count)
}

///|
/// The table a mode selects, and the bytes its description used.
fn Decoder::sequence_table(
  self : Decoder,
  mode : Int32,
  previous : Fse?,
  store : Fse,
  predefined : Fse,
  at : Int32,
  max_log : Int32,
  max_symbol : Int32,
  name : String,
) -> (Fse, Int32) raise Stop {
  match mode {
    0 => (predefined, 0)
    1 => {
      if at >= self.block_size {
        raise corrupt("an RLE \{name} code past its block")
      }
      let symbol = self.block[at]
      if symbol.to_int() > max_symbol {
        raise corrupt("an RLE \{name} code out of range")
      }
      store.set_rle(symbol)
      (store, 1)
    }
    2 => {
      let used = store.read(
        self.block,
        at,
        self.block_size,
        max_log,
        max_symbol,
        self.scratch,
      )
      (store, used)
    }
    _ =>
      match previous {
        Some(table) => (table, 0)
        None => raise corrupt("repeated \{name} codes before any table")
      }
  }
}

///|
/// Copies `n` literals from `at`, within the block limit.
fn Decoder::put_literals(
  self : Decoder,
  at : Int32,
  n : Int32,
) -> Unit raise Stop {
  if self.block_out + n > self.block_max {
    raise corrupt("a block that decodes past the block limit")
  }
  self.reserve_window(n)
  self.put_array(self.literals, at, n)
}

///|
/// Makes room for `n` bytes of a compressed block. The block decodes to at
/// most `block_max` bytes, no more than the window, and no output was
/// pending when it started, so the room is always there.
fn Decoder::reserve_window(self : Decoder, n : Int32) -> Unit raise Stop {
  guard self.ensure_space(n) else {
    raise corrupt("a block that does not fit the window")
  }
}

///|
/// Decodes `count` sequences from the bitstream `block[at:block_size]` and
/// executes each as it comes, then copies the remaining literals. The read
/// position is a local here, and the states' tables are read directly, so
/// that the loop keeps them in registers; `BackwardBits` holds it only for
/// the stream's start and its end check.
fn Decoder::execute(
  self : Decoder,
  ll : Fse,
  of : Fse,
  ml : Fse,
  at : Int32,
  count : Int32,
) -> Unit raise Stop {
  let bits = BackwardBits::new(self.block, at, self.block_size)
  let mut ll_state = bits.read(ll.log)
  let mut of_state = bits.read(of.log)
  let mut ml_state = bits.read(ml.log)
  let data = self.block
  let mut pos = bits.pos
  let rep = self.rep
  let mut lit = 0
  for i in 0..<count {
    if pos < 0 {
      raise corrupt("a sequences bitstream that ends early")
    }
    // Each state's entry, loaded once: its symbol now, and its next state's
    // base and bits after the extra bits.
    let of_entry = of.entry_of(of_state)
    let ml_entry = ml.entry_of(ml_state)
    let ll_entry = ll.entry_of(ll_state)
    let of_code = entry_symbol(of_entry)
    let ml_code = entry_symbol(ml_entry)
    let ll_code = entry_symbol(ll_entry)
    if of_code > MAX_OF_CODE {
      raise corrupt("an offset code above \{MAX_OF_CODE}")
    }
    // ml_code and ll_code index tables of their alphabets' sizes: the
    // symbols of tables built from distributions over them.
    let ml_extra = ml_bits[ml_code]
    let ll_extra = ll_bits[ll_code]
    let mut offset_bits = 0
    let mut ml_add = 0
    let mut ll_add = 0
    let last = i == count - 1
    if wide_reads(pos - 62) {
      // `top_bits` reads at `pos`, after at most 30 + 16 bits, and after at
      // most 30 + 16 + 16 bits; then at most 9 + 9 + 8 bits are taken from
      // a word of 57.
      let mut w = top_bits(data, at, pos)
      offset_bits = take_bits(w, of_code)
      w = w << of_code
      ml_add = take_bits(w, ml_extra)
      w = w << ml_extra
      if of_code + ml_extra + ll_extra > 57 {
        pos -= of_code + ml_extra
        ll_add = take_bits(top_bits(data, at, pos), ll_extra)
        pos -= ll_extra
      } else {
        ll_add = take_bits(w, ll_extra)
        pos -= of_code + ml_extra + ll_extra
      }
      if !last {
        let mut w = top_bits(data, at, pos)
        let n = entry_nbits(ll_entry)
        ll_state = entry_base(ll_entry) + take_bits(w, n)
        w = w << n
        pos -= n
        let n = entry_nbits(ml_entry)
        ml_state = entry_base(ml_entry) + take_bits(w, n)
        w = w << n
        pos -= n
        let n = entry_nbits(of_entry)
        of_state = entry_base(of_entry) + take_bits(w, n)
        pos -= n
      }
    } else {
      offset_bits = if of_code <= 24 {
        back_bits(data, at, pos, of_code)
      } else {
        (back_bits(data, at, pos, of_code - 16) << 16) |
        back_bits(data, at, pos - (of_code - 16), 16)
      }
      pos -= of_code
      ml_add = back_bits(data, at, pos, ml_extra)
      pos -= ml_extra
      ll_add = back_bits(data, at, pos, ll_extra)
      pos -= ll_extra
      if !last {
        let n = entry_nbits(ll_entry)
        ll_state = entry_base(ll_entry) + back_bits(data, at, pos, n)
        pos -= n
        let n = entry_nbits(ml_entry)
        ml_state = entry_base(ml_entry) + back_bits(data, at, pos, n)
        pos -= n
        let n = entry_nbits(of_entry)
        of_state = entry_base(of_entry) + back_bits(data, at, pos, n)
        pos -= n
      }
    }
    let offset_value = (1 << of_code) + offset_bits
    let match_len = ml_base[ml_code] + ml_add
    let lit_len = ll_base[ll_code] + ll_add
    // The offset, and the repeat offsets after it (RFC 8878 section
    // 3.1.1.5).
    let @seqenc.Distance(distance) = rep.resolve(
      @seqenc.OffsetValue(offset_value.reinterpret_as_uint()),
      lit_len,
    )
    let offset = distance.reinterpret_as_int()
    if lit_len > self.literals_len - lit {
      raise corrupt("a sequence with more literals than the block holds")
    }
    if !self.put_literals_fast(lit, lit_len) {
      self.put_literals(lit, lit_len)
    }
    lit += lit_len
    if self.block_out + match_len > self.block_max {
      raise corrupt("a block that decodes past the block limit")
    }
    if offset == 0 || offset > self.filled {
      // Before the frame's output: only a dictionary has bytes there.
      self.copy_from_dictionary(offset, match_len)
    } else if !self.copy_back_fast(offset, match_len) {
      self.reserve_window(match_len)
      self.copy_back(offset, match_len)
    }
  }
  if pos != 0 {
    raise corrupt("a sequences bitstream that is not used up exactly")
  }
  self.put_literals(lit, self.literals_len - lit)
}

///|
/// Whether `n` bytes fit at `wpos` without wrapping the window, growing it
/// or handing out pending output: the case `ensure_space(n)` returns at
/// once, with nothing to split.
#inline
fn Decoder::fits(self : Decoder, n : Int32) -> Bool {
  let cap = self.ring.length()
  self.wpos + n <= cap && (cap < self.ring_max || self.pending + n <= cap)
}

///|
/// Whether the 8 bytes after `n` bytes at `wpos` hold no window history, so
/// that a copy may write past its end (`wild_copy`): before the window has
/// wrapped, and with room for them. Only on native and Wasm, which have
/// the eight-byte copies.
#inline
fn Decoder::spare(self : Decoder, n : Int32) -> Bool {
  // History is the `filled` bytes before `wpos`, around the end once the
  // window has wrapped.
  wide_copies &&
  self.wpos + n + 8 <= self.ring.length() - (self.filled - self.wpos).max(0)
}

///|
/// `put_literals` when the literals fit (`fits`): false, having done
/// nothing, otherwise or when the block limit would be passed, which
/// `put_literals` then reports.
fn Decoder::put_literals_fast(self : Decoder, at : Int32, n : Int32) -> Bool {
  guard self.block_out + n <= self.block_max && self.fits(n) else {
    return false
  }
  // at + n <= literals_len, checked by the caller, and fits(n).
  if self.spare(n) && at + n + 8 <= self.literals.length() {
    wild_copy(self.ring, self.wpos, self.literals, at, n)
  } else {
    copy_forward(self.ring, self.wpos, self.literals, at, n)
  }
  self.advance(n)
  true
}

///|
/// `copy_back` when the match and its source fit without wrapping: false,
/// having done nothing, otherwise. The caller has checked the offset and
/// the block limit.
fn Decoder::copy_back_fast(self : Decoder, dist : Int32, n : Int32) -> Bool {
  let src = self.wpos - dist
  guard src >= 0 && self.fits(n) else { return false }
  let ring = self.ring
  let dst = self.wpos
  if self.spare(n) {
    wild_match(ring, dst, dist, n)
  } else if dist >= n {
    copy_forward(ring, dst, ring, src, n)
  } else {
    // Overlapping: each byte may repeat one written in this copy, so the
    // copy goes forward in steps no longer than `dist`.
    @blit.forward(ring, dst, src, n)
  }
  self.advance(n)
  true
}
