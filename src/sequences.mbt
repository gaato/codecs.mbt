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
/// executes each as it comes, then copies the remaining literals.
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
  let rep = self.rep
  let mut lit = 0
  for i in 0..<count {
    if bits.pos < 0 {
      raise corrupt("a sequences bitstream that ends early")
    }
    let of_code = of.symbol_of(of_state)
    let ml_code = ml.symbol_of(ml_state)
    let ll_code = ll.symbol_of(ll_state)
    if of_code > MAX_OF_CODE {
      raise corrupt("an offset code above \{MAX_OF_CODE}")
    }
    let offset_value = (1 << of_code) + bits.read_long(of_code)
    let match_len = ml_base[ml_code] + bits.read(ml_bits[ml_code])
    let lit_len = ll_base[ll_code] + bits.read(ll_bits[ll_code])
    if i < count - 1 {
      ll_state = ll.next(ll_state, bits)
      ml_state = ml.next(ml_state, bits)
      of_state = of.next(of_state, bits)
    }
    // The offset, and the repeat offsets after it (RFC 8878 section
    // 3.1.2.5).
    let offset = if offset_value > 3 {
      let offset = offset_value - 3
      rep[2] = rep[1]
      rep[1] = rep[0]
      rep[0] = offset
      offset
    } else {
      let index = offset_value - 1 + (if lit_len == 0 { 1 } else { 0 })
      if index == 0 {
        rep[0]
      } else {
        let offset = if index < 3 { rep[index] } else { rep[0] - 1 }
        if index > 1 {
          rep[2] = rep[1]
        }
        rep[1] = rep[0]
        rep[0] = offset
        offset
      }
    }
    if lit_len > self.literals_len - lit {
      raise corrupt("a sequence with more literals than the block holds")
    }
    self.put_literals(lit, lit_len)
    lit += lit_len
    if offset == 0 || offset > self.filled {
      raise corrupt("an offset beyond the decoded data")
    }
    if self.block_out + match_len > self.block_max {
      raise corrupt("a block that decodes past the block limit")
    }
    self.reserve_window(match_len)
    self.copy_back(offset, match_len)
  }
  if bits.pos != 0 {
    raise corrupt("a sequences bitstream that is not used up exactly")
  }
  self.put_literals(lit, self.literals_len - lit)
}
