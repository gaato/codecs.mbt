// The literals section of a compressed block (RFC 8878 section 3.1.1.3.1).

///|
/// Makes `literals` hold at least `n` bytes.
fn Decoder::reserve_literals(self : Decoder, n : Int32) -> Unit {
  if self.literals.length() < n {
    self.literals = FixedArray::make(n, b'\x00')
  }
}

///|
/// Decodes the literals section at the start of `block[0:size]` into
/// `literals[0:literals_len]`. Returns where the sequences section starts.
fn Decoder::decode_literals(self : Decoder, size : Int32) -> Int32 raise Stop {
  let block = self.block
  let b0 = block[0].to_int()
  let block_type = b0 & 3
  let size_format = (b0 >> 2) & 3
  if block_type < 2 {
    // Raw or RLE: a 1-, 2- or 3-byte header with the regenerated size.
    let (header, regenerated) = match size_format {
      0 | 2 => (1, b0 >> 3)
      1 => {
        if size < 2 {
          raise corrupt("a literals header past its block")
        }
        (2, (b0 >> 4) + (block[1].to_int() << 4))
      }
      _ => {
        if size < 3 {
          raise corrupt("a literals header past its block")
        }
        (3, (b0 >> 4) + (block[1].to_int() << 4) + (block[2].to_int() << 12))
      }
    }
    if regenerated > self.block_max {
      raise corrupt("more literals than the block limit")
    }
    self.reserve_literals(regenerated)
    self.literals_len = regenerated
    if block_type == 0 {
      if header + regenerated > size {
        raise corrupt("raw literals past their block")
      }
      FixedArray::unsafe_blit(self.literals, 0, block, header, regenerated)
      return header + regenerated
    }
    if header + 1 > size {
      raise corrupt("RLE literals past their block")
    }
    self.literals.fill(block[header], start=0, end=regenerated)
    return header + 1
  }
  // Compressed or treeless: both sizes, in 10, 14 or 18 bits each.
  let (header, width) = match size_format {
    0 | 1 => (3, 10)
    2 => (4, 14)
    _ => (5, 18)
  }
  if size < header {
    raise corrupt("a literals header past its block")
  }
  let mut fields : UInt64 = 0
  for i = header - 1; i >= 0; i = i - 1 {
    fields = (fields << 8) | block[i].to_uint64()
  }
  let mask = (1UL << width) - 1
  let regenerated = ((fields >> 4) & mask).to_int()
  let compressed = ((fields >> (4 + width)) & mask).to_int()
  if regenerated > self.block_max {
    raise corrupt("more literals than the block limit")
  }
  // Four streams need at least 6 literals, or the last stream's length would
  // be negative (RFC 8878 erratum 7297).
  if size_format != 0 && regenerated < 6 {
    raise corrupt("fewer than 6 literals in four Huffman streams")
  }
  let end = header + compressed
  if end > size {
    raise corrupt("compressed literals past their block")
  }
  let mut streams = header
  if block_type == 2 {
    streams += self.huffman.read(block, header, end, self.scratch)
    self.huffman_valid = true
  } else if !self.huffman_valid {
    raise corrupt("treeless literals before any Huffman table")
  }
  self.reserve_literals(regenerated)
  self.literals_len = regenerated
  self.huffman.decode(
    block,
    streams,
    end,
    self.literals,
    regenerated,
    size_format != 0,
  )
  end
}
