// Ending a block, as libdeflate's deflate_finish_block and
// deflate_flush_block do: build the block's Huffman codes, cost the three
// kinds of block exactly, and write the cheapest; on a tie, stored, then
// fixed, then dynamic.

///|
/// Builds the codes of the block the parser completed and writes it.
fn Deflater::finish_block(
  self : Deflater,
  begin : Int32,
  length : Int32,
  is_final : Bool,
) -> Unit {
  self.litlen_freqs[END_OF_BLOCK] += 1
  let maker = self.maker.unwrap()
  maker.make(
    self.litlen_freqs,
    NUM_LITLEN_SYMS,
    MAX_LITLEN_CODEWORD_LEN,
    self.litlen_lens,
    self.litlen_codes,
  )
  maker.make(
    self.offset_freqs,
    NUM_OFFSET_SYMS,
    MAX_OFFSET_CODEWORD_LEN,
    self.offset_lens,
    self.offset_codes,
  )
  self.flush_block(begin, length, is_final)
}

///|
/// The code-length code of the dynamic code, and the items that write the
/// lengths with it (`symbol | extra << 5`), as zlib and libdeflate run-length
/// code them. Returns how many literal/length and distance codes the header
/// declares, how many items there are, and how many code-length code lengths
/// it writes.
fn Deflater::precompute_huffman_header(
  self : Deflater,
) -> (Int32, Int32, Int32, Int32) {
  let mut nlit = NUM_LITLEN_SYMS
  while nlit > 257 && self.litlen_lens[nlit - 1] == 0 {
    nlit -= 1
  }
  let mut noff = NUM_OFFSET_SYMS
  while noff > 1 && self.offset_lens[noff - 1] == 0 {
    noff -= 1
  }
  let lens = self.all_lens
  for i in 0..<nlit {
    lens[i] = self.litlen_lens[i]
  }
  for i in 0..<noff {
    lens[nlit + i] = self.offset_lens[i]
  }
  let num_lens = nlit + noff
  let freqs = self.precode_freqs
  freqs.fill(0)
  let items = self.precode_items
  let mut nitems = 0
  let mut run_start = 0
  while run_start != num_lens {
    let len = lens[run_start]
    let mut run_end = run_start + 1
    while run_end != num_lens && lens[run_end] == len {
      run_end += 1
    }
    if len == 0 {
      // Runs of zeros: 18 for 11 to 138, 17 for 3 to 10.
      while run_end - run_start >= 11 {
        let extra = (run_end - run_start - 11).min(0x7F)
        freqs[18] += 1
        items[nitems] = 18 | (extra << 5)
        nitems += 1
        run_start += 11 + extra
      }
      if run_end - run_start >= 3 {
        let extra = (run_end - run_start - 3).min(0x7)
        freqs[17] += 1
        items[nitems] = 17 | (extra << 5)
        nitems += 1
        run_start += 3 + extra
      }
    } else if run_end - run_start >= 4 {
      // A length, then 16 for 3 to 6 more of it.
      freqs[len] += 1
      items[nitems] = len
      nitems += 1
      run_start += 1
      while true {
        let extra = (run_end - run_start - 3).min(0x3)
        freqs[16] += 1
        items[nitems] = 16 | (extra << 5)
        nitems += 1
        run_start += 3 + extra
        if run_end - run_start < 3 {
          break
        }
      }
    }
    while run_start != run_end {
      freqs[len] += 1
      items[nitems] = len
      nitems += 1
      run_start += 1
    }
  }
  self.maker
  .unwrap()
  .make(
    freqs,
    NUM_PRECODE_SYMS,
    MAX_PRE_CODEWORD_LEN,
    self.precode_lens,
    self.precode_codes,
  )
  let mut nexplicit = NUM_PRECODE_SYMS
  while nexplicit > 4 &&
        self.precode_lens[precode_lens_permutation[nexplicit - 1]] == 0 {
    nexplicit -= 1
  }
  (nlit, noff, nitems, nexplicit)
}

///|
/// Writes the block from `begin`, of `length` bytes, the cheapest way.
fn Deflater::flush_block(
  self : Deflater,
  begin : Int32,
  length : Int32,
  is_final : Bool,
) -> Unit {
  let (nlit, noff, nitems, nexplicit) = self.precompute_huffman_header()
  let litlen_freqs = self.litlen_freqs
  let offset_freqs = self.offset_freqs
  let litlen_lens = self.litlen_lens
  let offset_lens = self.offset_lens
  // Costs in bits, each with the 3-bit block header.
  let mut dynamic_cost = 3 + 5 + 5 + 4 + 3 * nexplicit
  let mut static_cost = 3
  for sym in 0..<NUM_PRECODE_SYMS {
    dynamic_cost += self.precode_freqs[sym] *
      (extra_precode_bits[sym] + self.precode_lens[sym])
  }
  for sym in 0..<144 {
    dynamic_cost += litlen_freqs[sym] * litlen_lens[sym]
    static_cost += litlen_freqs[sym] * 8
  }
  for sym in 144..<256 {
    dynamic_cost += litlen_freqs[sym] * litlen_lens[sym]
    static_cost += litlen_freqs[sym] * 9
  }
  dynamic_cost += litlen_lens[END_OF_BLOCK]
  static_cost += 7
  for slot in 0..<29 {
    let sym = FIRST_LEN_SYM + slot
    let extra = extra_length_bits[slot]
    dynamic_cost += litlen_freqs[sym] * (extra + litlen_lens[sym])
    static_cost += litlen_freqs[sym] * (extra + static_litlen_lens[sym])
  }
  for sym in 0..<30 {
    let extra = extra_offset_bits[sym]
    dynamic_cost += offset_freqs[sym] * (extra + offset_lens[sym])
    static_cost += offset_freqs[sym] * (extra + 5)
  }
  let uncompressed_cost = 3 +
    (-(self.bitcount + 3) & 7) +
    32 +
    40 * ((length + MAX_STORED_LENGTH - 1) / MAX_STORED_LENGTH - 1) +
    8 * length
  let best_cost = dynamic_cost.min(static_cost.min(uncompressed_cost))
  if best_cost == uncompressed_cost {
    self.write_stored(begin, length, is_final)
    return
  }
  let final_bit = if is_final { 1 } else { 0 }
  let (lit_lens, lit_codes, off_lens, off_codes) = if best_cost == static_cost {
    self.put(final_bit | (1 << 1), 3)
    (
      static_litlen_lens, static_litlen_codes, static_offset_lens, static_offset_codes,
    )
  } else {
    self.put(final_bit | (2 << 1), 3)
    self.put(nlit - 257, 5)
    self.put(noff - 1, 5)
    self.put(nexplicit - 4, 4)
    for i in 0..<nexplicit {
      self.put(self.precode_lens[precode_lens_permutation[i]], 3)
    }
    for i in 0..<nitems {
      let item = self.precode_items[i]
      let sym = item & 0x1F
      self.put(self.precode_codes[sym], self.precode_lens[sym])
      self.put(item >> 5, extra_precode_bits[sym])
    }
    (self.litlen_lens, self.litlen_codes, self.offset_lens, self.offset_codes)
  }
  // Each match length's codeword with its extra bits.
  let full_codes = self.len_full_codes
  let full_lens = self.len_full_lens
  for len in MIN_MATCH_LEN..<=MAX_MATCH_LEN {
    let slot = length_slot[len]
    let sym = FIRST_LEN_SYM + slot
    full_codes[len] = lit_codes[sym] |
      ((len - length_slot_base[slot]) << lit_lens[sym])
    full_lens[len] = lit_lens[sym] + extra_length_bits[slot]
  }
  // The sequences, with the bit writer's state in locals: at most 16 bits
  // go in at a time onto fewer than 16 held, and every 16 held go out.
  let data = self.buf
  let out = self.out
  let seq_litlen = self.seq_litlen
  let seq_offset = self.seq_offset
  let mut pos = self.out_pos
  let mut bits = self.bits
  let mut count = self.bitcount
  let mut in_next = begin
  for i in 0..<=self.nseq {
    let entry = seq_litlen[i]
    for _ in 0..<(entry & 0x1FFFF) {
      let lit = data[in_next].to_int()
      bits = bits | (lit_codes[lit].reinterpret_as_uint() << count)
      count += lit_lens[lit]
      if count >= 16 {
        out[pos] = bits.to_byte()
        out[pos + 1] = (bits >> 8).to_byte()
        pos += 2
        bits = bits >> 16
        count -= 16
      }
      in_next += 1
    }
    let length = (entry >> 17) & 0x1FF
    if length == 0 {
      break
    }
    // The length's codeword and extra bits, at most 14 + 5: split past 16.
    let full = full_codes[length]
    let full_len = full_lens[length]
    if full_len <= 16 {
      bits = bits | (full.reinterpret_as_uint() << count)
      count += full_len
    } else {
      let code_len = full_len - extra_length_bits[length_slot[length]]
      bits = bits |
        ((full & ((1 << code_len) - 1)).reinterpret_as_uint() << count)
      count += code_len
      if count >= 16 {
        out[pos] = bits.to_byte()
        out[pos + 1] = (bits >> 8).to_byte()
        pos += 2
        bits = bits >> 16
        count -= 16
      }
      bits = bits | ((full >> code_len).reinterpret_as_uint() << count)
      count += full_len - code_len
    }
    if count >= 16 {
      out[pos] = bits.to_byte()
      out[pos + 1] = (bits >> 8).to_byte()
      pos += 2
      bits = bits >> 16
      count -= 16
    }
    // The offset's codeword, then its extra bits.
    let slot = entry >> 26
    let offset = seq_offset[i].to_int()
    bits = bits | (off_codes[slot].reinterpret_as_uint() << count)
    count += off_lens[slot]
    if count >= 16 {
      out[pos] = bits.to_byte()
      out[pos + 1] = (bits >> 8).to_byte()
      pos += 2
      bits = bits >> 16
      count -= 16
    }
    bits = bits |
      ((offset - offset_slot_base[slot]).reinterpret_as_uint() << count)
    count += extra_offset_bits[slot]
    if count >= 16 {
      out[pos] = bits.to_byte()
      out[pos + 1] = (bits >> 8).to_byte()
      pos += 2
      bits = bits >> 16
      count -= 16
    }
    in_next += length
  }
  self.out_pos = pos
  self.bits = bits
  self.bitcount = count
  self.put(lit_codes[END_OF_BLOCK], lit_lens[END_OF_BLOCK])
}
