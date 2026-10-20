// The literals section header (RFC 8878 section 3.1.1.3.1.1), at the start
// of a compressed block.

///|
/// Literals_Block_Type.
pub(all) enum LiteralsType {
  /// Raw_Literals_Block: the literals as they are.
  RawLiterals
  /// RLE_Literals_Block: one byte, repeated.
  RleLiterals
  /// Compressed_Literals_Block: a Huffman tree description, then streams.
  CompressedLiterals
  /// Treeless_Literals_Block: streams with the previous Huffman table.
  TreelessLiterals
} derive(Eq, @debug.Debug)

///|
pub extend LiteralsType with Eq::{equal, not_equal}

///|
pub extend LiteralsType with @debug.Debug::{to_repr}

///|
/// A decoded literals section header whose section fits its block.
pub(all) struct LiteralsHeader {
  block_type : LiteralsType
  /// Size_Format, the two bits after the type. For compressed and treeless
  /// literals, 0 means one stream and anything else four.
  size_format : Int32
  /// The header's length: 1 to 5 bytes.
  header_len : Int32
  /// Regenerated_Size: how many literals the section decodes to.
  regenerated : Int32
  /// The bytes the section takes after its header: Regenerated_Size for raw
  /// literals, 1 for RLE, Compressed_Size for compressed and treeless.
  compressed : Int32
} derive(Eq, @debug.Debug)

///|
pub extend LiteralsHeader with Eq::{equal, not_equal}

///|
pub extend LiteralsHeader with @debug.Debug::{to_repr}

///|
/// Whether the literals come in four Huffman streams after a jump table.
pub fn LiteralsHeader::four_streams(self : LiteralsHeader) -> Bool {
  self.block_type is (CompressedLiterals | TreelessLiterals) &&
  self.size_format != 0
}

///|
/// Parses the literals section header at the start of `section`, a
/// compressed block, and checks that the section fits it: the header, then
/// what follows it, within `section`, and no more literals than
/// `block_max`, Block_Maximum_Size.
pub fn parse_literals_header(
  section : ArrayView[Byte],
  block_max : Int32,
) -> Result[LiteralsHeader, String] {
  decode_literals_header(
    byte_at(section, 0),
    byte_at(section, 1),
    byte_at(section, 2),
    byte_at(section, 3),
    byte_at(section, 4),
    section.length(),
    block_max,
  )
}

///|
/// `parse_literals_header` on the section's first five bytes `b0` to `b4`
/// and its length `avail`. The bytes past `avail` do not change the result;
/// pass 0.
pub fn decode_literals_header(
  b0 : Int32,
  b1 : Int32,
  b2 : Int32,
  b3 : Int32,
  b4 : Int32,
  avail : Int32,
  block_max : Int32,
) -> Result[LiteralsHeader, String] {
  let size_format = (b0 >> 2) & 3
  match b0 & 3 {
    0 | 1 as raw_or_rle => {
      // Raw or RLE: a 1-, 2- or 3-byte header with the regenerated size.
      let (header_len, regenerated) = match size_format {
        0 | 2 => (1, (b0 >> 3) & 31)
        1 => (2, ((b0 >> 4) & 15) | ((b1 & 0xFF) << 4))
        _ => (3, ((b0 >> 4) & 15) | ((b1 & 0xFF) << 4) | ((b2 & 0xFF) << 12))
      }
      let (block_type, compressed) = if raw_or_rle == 0 {
        (RawLiterals, regenerated)
      } else {
        (RleLiterals, 1)
      }
      if avail < header_len {
        Err("a literals header past its block")
      } else if regenerated > block_max {
        Err("more literals than the block limit")
      } else if header_len + compressed > avail {
        Err(
          if raw_or_rle == 0 {
            "raw literals past their block"
          } else {
            "RLE literals past their block"
          },
        )
      } else {
        Ok({ block_type, size_format, header_len, regenerated, compressed, })
      }
    }
    compressed_or_treeless => {
      // Compressed or treeless: both sizes, in 10, 14 or 18 bits each.
      let (header_len, width) = match size_format {
        0 | 1 => (3, 10)
        2 => (4, 14)
        _ => (5, 18)
      }
      let fields = (
          (b0 & 0xFF).to_uint64() |
          ((b1 & 0xFF).to_uint64() << 8) |
          ((b2 & 0xFF).to_uint64() << 16) |
          ((b3 & 0xFF).to_uint64() << 24) |
          ((b4 & 0xFF).to_uint64() << 32)
        ) &
        ((1UL << (8 * header_len)) - 1)
      let mask = (1UL << width) - 1
      let regenerated = ((fields >> 4) & mask).to_int()
      let compressed = ((fields >> (4 + width)) & mask).to_int()
      if avail < header_len {
        Err("a literals header past its block")
      } else if regenerated > block_max {
        Err("more literals than the block limit")
      } else if size_format != 0 && regenerated < 6 {
        // Four streams need at least 6 literals, or the last stream's
        // length would be negative (RFC 8878 erratum 7297).
        Err("fewer than 6 literals in four Huffman streams")
      } else if header_len + compressed > avail {
        Err("compressed literals past their block")
      } else {
        Ok({
          block_type: if compressed_or_treeless == 2 {
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
}
