///|
/// The literals section header as RFC 8878 section 3.1.1.3.1.1 lays it
/// out, read with division rather than shifts, followed by the decoder's
/// checks in its order. `bytes` holds five bytes; `avail` is the block size.
fn literals_header_ref(
  bytes : Array[Int32],
  avail : Int32,
  block_max : Int32,
) -> Result[@header.LiteralsHeader, String] {
  let b0 = bytes[0]
  let literals_block_type = b0 % 4
  let size_format = b0 / 4 % 4
  // The header as one little-endian number, up to 5 bytes.
  let value = bytes[0].to_int64() +
    bytes[1].to_int64() * 0x100L +
    bytes[2].to_int64() * 0x10000L +
    bytes[3].to_int64() * 0x1000000L +
    bytes[4].to_int64() * 0x100000000L
  if literals_block_type < 2 {
    // Raw_Literals_Block or RLE_Literals_Block.
    let (header_len, regenerated) = match size_format {
      // Size_Format 00 or 10: 5 bits of Regenerated_Size in 1 byte.
      0 | 2 => (1, value / 8 % 32)
      // 01: 12 bits in 2 bytes.
      1 => (2, value / 16 % 4096)
      // 11: 20 bits in 3 bytes.
      _ => (3, value / 16 % 1048576)
    }
    let regenerated = regenerated.to_int()
    let follows = if literals_block_type == 0 { regenerated } else { 1 }
    if avail < header_len {
      Err("a literals header past its block")
    } else if regenerated > block_max {
      Err("more literals than the block limit")
    } else if header_len + follows > avail {
      Err(
        if literals_block_type == 0 {
          "raw literals past their block"
        } else {
          "RLE literals past their block"
        },
      )
    } else {
      Ok({
        block_type: if literals_block_type == 0 {
          RawLiterals
        } else {
          RleLiterals
        },
        size_format,
        header_len,
        regenerated,
        compressed: follows,
      })
    }
  } else {
    // Compressed_Literals_Block or Treeless_Literals_Block: Size_Format 00
    // is one stream, the others four; both sizes take 10, 10, 14 or 18
    // bits, in a header of 3, 3, 4 or 5 bytes.
    let (header_len, bits) = [(3, 10), (3, 10), (4, 14), (5, 18)][size_format]
    let field = 1L << bits
    let header_value = value % (1L << (8 * header_len))
    let regenerated = (header_value / 16 % field).to_int()
    let compressed = (header_value / 16 / field % field).to_int()
    if avail < header_len {
      Err("a literals header past its block")
    } else if regenerated > block_max {
      Err("more literals than the block limit")
    } else if size_format != 0 && regenerated < 6 {
      Err("fewer than 6 literals in four Huffman streams")
    } else if header_len + compressed > avail {
      Err("compressed literals past their block")
    } else {
      Ok({
        block_type: if literals_block_type == 2 {
          CompressedLiterals
        } else {
          TreelessLiterals
        },
        size_format,
        header_len,
        regenerated,
        compressed,
      })
    }
  }
}

///|
/// Checks `decode_literals_header` against the reference, and
/// `parse_literals_header` on a block of `avail` bytes that starts with
/// `bytes` (zeros past them).
fn check_literals(
  bytes : Array[Int32],
  avail : Int32,
  block_max : Int32,
) -> Unit raise {
  let expected = literals_header_ref(bytes, avail, block_max)
  let actual = @header.decode_literals_header(
    bytes[0],
    bytes[1],
    bytes[2],
    bytes[3],
    bytes[4],
    avail,
    block_max,
  )
  if actual != expected {
    fail("\{Repr(bytes)}, avail \{avail}, limit \{block_max}: \{Repr(actual)}")
  }
  // Bytes past the block do not count: the parser reads them as zero.
  if avail <= 8 {
    let block = [
      for i in 0..<avail => if i < 5 { bytes[i].to_byte() } else { 0 }
    ]
    let padded = [ for i in 0..<5 => if i < avail { bytes[i] } else { 0 } ]
    assert_eq(
      @header.parse_literals_header(block[:], block_max),
      literals_header_ref(padded, avail, block_max),
    )
  }
}

///|
test "literals headers: every first byte over a grid of the others" {
  let edges = [0, 1, 0x3F, 0x40, 0x80, 0xC0, 0xFF]
  let avails = [0, 1, 2, 3, 4, 5, 6, 64, 1 << 17]
  for b0 in 0..<256 {
    for b1 in edges {
      for b2 in edges {
        for b3 in [0, 0x55, 0xFF] {
          for b4 in [0, 0xAA, 0xFF] {
            for avail in avails {
              for block_max in [1024, 1 << 17] {
                check_literals([b0, b1, b2, b3, b4], avail, block_max)
              }
            }
          }
        }
      }
    }
  }
}

///|
/// A seeded pseudo-random generator (a 32-bit LCG).
priv struct Rng {
  mut state : UInt32
}

///|
/// A number in `0..<bound`.
fn Rng::below(self : Rng, bound : Int32) -> Int32 {
  self.state = self.state * 1664525 + 1013904223
  (self.state >> 8).reinterpret_as_int() % bound
}

///|
test "literals headers: random headers near their sizes" {
  let rng = { state: 7, }
  for _ in 0..<200000 {
    let bytes = [ for _ in 0..<5 => rng.below(256) ]
    let block_max = [1, 6, 1024, 1 << 17][rng.below(4)]
    // Around the sizes the header itself declares, where the checks bite.
    let declared = match literals_header_ref(bytes, 1 << 20, 1 << 20) {
      Ok(h) => h.header_len + h.compressed
      Err(_) => rng.below(1 << 17)
    }
    let avail = (declared + rng.below(5) - 2).max(0)
    check_literals(bytes, avail, block_max)
  }
}

///|
test "literals headers: four streams and the erratum 7297 bound" {
  // Compressed, Size_Format 01 (four streams, 10-bit sizes): 5 literals are
  // refused, 6 taken.
  let header = (regenerated, compressed) => {
    let value = 2 | (1 << 2) | (regenerated << 4) | (compressed << 14)
    @header.decode_literals_header(
      value & 0xFF,
      (value >> 8) & 0xFF,
      value >> 16,
      0,
      0,
      100,
      1024,
    )
  }
  debug_inspect(
    header(5, 10),
    content=(
      #|Err("fewer than 6 literals in four Huffman streams")
    ),
  )
  let six = header(6, 10)
  debug_inspect(
    six,
    content=(
      #|Ok(
      #|  {
      #|    block_type: CompressedLiterals,
      #|    size_format: 1,
      #|    header_len: 3,
      #|    regenerated: 6,
      #|    compressed: 10,
      #|  },
      #|)
    ),
  )
  assert_true(six is Ok(h) && h.four_streams())
  // One stream needs no such bound; raw and RLE literals have no streams.
  let one = @header.decode_literals_header(2 | (1 << 4), 0x40, 0, 0, 0, 4, 1024)
  assert_true(one is Ok(h) && !h.four_streams())
  let raw = @header.decode_literals_header(0, 0, 0, 0, 0, 1, 1024)
  assert_true(raw is Ok(h) && !h.four_streams())
}
