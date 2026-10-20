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
  let section = checked(
    @header.parse_literals_header(block[0:size], self.block_max),
  )
  let header = section.header_len
  let regenerated = section.regenerated
  let end = header + section.compressed
  match section.block_type {
    RawLiterals => {
      self.reserve_literals(regenerated)
      self.literals_len = regenerated
      FixedArray::unsafe_blit(self.literals, 0, block, header, regenerated)
    }
    RleLiterals => {
      self.reserve_literals(regenerated)
      self.literals_len = regenerated
      self.literals.fill(block[header], start=0, end=regenerated)
    }
    CompressedLiterals | TreelessLiterals as block_type => {
      let mut streams = header
      if block_type is CompressedLiterals {
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
        section.four_streams(),
      )
    }
  }
  end
}
