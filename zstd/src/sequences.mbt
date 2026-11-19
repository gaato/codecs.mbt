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
/// Native and Wasm benefit from keeping the window counters in the loop.
#cfg(any(target="native", target="wasm"))
const INLINE_SEQUENCE_COPIES : Bool = true

///|
/// Keep the smaller sequence loop on JS and Wasm GC.
#cfg(not(any(target="native", target="wasm")))
const INLINE_SEQUENCE_COPIES : Bool = false

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
  let @seqenc.Distance(first) = rep.get(0)
  let @seqenc.Distance(second) = rep.get(1)
  let @seqenc.Distance(third) = rep.get(2)
  let mut r0 = first
  let mut r1 = second
  let mut r2 = third
  let mut lit = 0
  let literals = self.literals
  let literals_len = self.literals_len
  let ring_max = self.ring_max
  let window = self.window
  let block_max = self.block_max
  let mut ring = self.ring
  let mut cap = ring.length()
  let mut wpos = self.wpos
  let mut filled = self.filled
  let mut block_out = self.block_out
  // This block starts with nothing pending, and block_max <= ring_max.
  // Even if it grows the ring, it can never have to drain mid-block.
  for i in 0..<count {
    if pos < 0 {
      if INLINE_SEQUENCE_COPIES {
        self.save_sequence_window(wpos, filled, block_out)
      }
      raise corrupt("a sequences bitstream that ends early")
    }
    // Each initial state uses log bits. Every transition's base plus any
    // value of its nbits also lies in 0..<1 << log, within the entry array.
    let of_entry = of.entry.unsafe_get(of_state)
    let ml_entry = ml.entry.unsafe_get(ml_state)
    let ll_entry = ll.entry.unsafe_get(ll_state)
    let of_code = entry_symbol(of_entry)
    let ml_code = entry_symbol(ml_entry)
    let ll_code = entry_symbol(ll_entry)
    if of_code > MAX_OF_CODE {
      if INLINE_SEQUENCE_COPIES {
        self.save_sequence_window(wpos, filled, block_out)
      }
      raise corrupt("an offset code above \{MAX_OF_CODE}")
    }
    // The predefined, RLE and transmitted tables (including dictionaries)
    // bound these symbols by MAX_ML_CODE and MAX_LL_CODE, respectively.
    let ml_extra = ml_bits.unsafe_get(ml_code)
    let ll_extra = ll_bits.unsafe_get(ll_code)
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
    // The same alphabet bounds apply to the base tables.
    let match_len = ml_base.unsafe_get(ml_code) + ml_add
    let lit_len = ll_base.unsafe_get(ll_code) + ll_add
    // The offset, and the repeat offsets after it (RFC 8878 section
    // 3.1.1.5).
    let v = offset_value.reinterpret_as_uint()
    let distance = if v > 3 {
      let d = v - 3
      r2 = r1
      r1 = r0
      r0 = d
      d
    } else {
      let index = v.reinterpret_as_int() -
        1 +
        (if lit_len == 0 { 1 } else { 0 })
      let d = match index {
        0 => r0
        1 => r1
        2 => r2
        _ => r0 - 1
      }
      if index != 0 {
        if index > 1 {
          r2 = r1
        }
        r1 = r0
        r0 = d
      }
      d
    }
    let offset = distance.reinterpret_as_int()
    if lit_len > literals_len - lit {
      if INLINE_SEQUENCE_COPIES {
        self.save_sequence_window(wpos, filled, block_out)
      }
      raise corrupt("a sequence with more literals than the block holds")
    }
    if INLINE_SEQUENCE_COPIES {
      let lit_end = wpos + lit_len
      if block_out + lit_len <= block_max && lit_end <= cap {
        // The literal range was checked above. Wild copies may overwrite
        // only spare space after the write, outside the filled history.
        if wide_copies &&
          lit_end + 8 <= cap - (filled - wpos).max(0) &&
          lit + lit_len + 8 <= literals.length() {
          wild_copy(ring, wpos, literals, lit, lit_len)
        } else {
          copy_forward(ring, wpos, literals, lit, lit_len)
        }
        wpos = if lit_end == ring_max { 0 } else { lit_end }
        filled = (filled + lit_len).min(window)
        block_out += lit_len
      } else {
        self.save_sequence_window(wpos, filled, block_out)
        self.put_literals(lit, lit_len)
        ring = self.ring
        cap = ring.length()
        wpos = self.wpos
        filled = self.filled
        block_out = self.block_out
      }
      if block_out + match_len > block_max {
        self.save_sequence_window(wpos, filled, block_out)
        raise corrupt("a block that decodes past the block limit")
      }
      let in_window = offset != 0 && offset <= filled
      let src = wpos - offset
      let match_end = wpos + match_len
      if in_window && src >= 0 && match_end <= cap {
        if wide_copies && match_end + 8 <= cap - (filled - wpos).max(0) {
          wild_match(ring, wpos, offset, match_len)
        } else if offset >= match_len {
          copy_forward(ring, wpos, ring, src, match_len)
        } else {
          // Overlapping: each byte may repeat one written in this copy.
          @blit.forward(ring, wpos, src, match_len)
        }
        wpos = if match_end == ring_max { 0 } else { match_end }
        filled = (filled + match_len).min(window)
        block_out += match_len
      } else {
        self.save_sequence_window(wpos, filled, block_out)
        if in_window {
          self.reserve_window(match_len)
          self.copy_back(offset, match_len)
        } else {
          // Before the frame's output: only a dictionary has bytes there.
          self.copy_from_dictionary(offset, match_len)
        }
        ring = self.ring
        cap = ring.length()
        wpos = self.wpos
        filled = self.filled
        block_out = self.block_out
      }
    } else {
      if !self.put_literals_fast(lit, lit_len) {
        self.put_literals(lit, lit_len)
      }
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
    lit += lit_len
  }
  if INLINE_SEQUENCE_COPIES {
    self.save_sequence_window(wpos, filled, block_out)
  }
  if pos != 0 {
    raise corrupt("a sequences bitstream that is not used up exactly")
  }
  // An error is terminal until reset. Only the next block needs the repeats.
  rep.set(r0, r1, r2)
  self.put_literals(lit, literals_len - lit)
}

///|
/// Publishes the loop's counters before a slow copy, at block end, or
/// before raising so the decoder can drain output from before the error.
fn Decoder::save_sequence_window(
  self : Decoder,
  wpos : Int32,
  filled : Int32,
  block_out : Int32,
) -> Unit {
  self.wpos = wpos
  self.pending = block_out
  self.filled = filled
  self.block_out = block_out
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
