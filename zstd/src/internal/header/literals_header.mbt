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
  match
    literals_header_of(
      b0 & 0xFF,
      b1 & 0xFF,
      b2 & 0xFF,
      b3 & 0xFF,
      b4 & 0xFF,
      avail,
      block_max,
    ) {
    Parsed(header) => Ok(header)
    Refused(1) => Err("a literals header past its block")
    Refused(2) => Err("more literals than the block limit")
    // Four streams need at least 6 literals, or the last stream's length
    // would be negative (RFC 8878 erratum 7297).
    Refused(3) => Err("fewer than 6 literals in four Huffman streams")
    Refused(_) =>
      Err(
        match b0 & 3 {
          0 => "raw literals past their block"
          1 => "RLE literals past their block"
          _ => "compressed literals past their block"
        },
      )
  }
}

///|
/// What `literals_header_of` makes of a header.
priv enum LiteralsParse {
  /// A header whose section fits its block.
  Parsed(LiteralsHeader)
  /// Why the header is refused: 1 for a header past the block, 2 for more
  /// literals than the block limit, 3 for four streams of fewer than 6
  /// literals, 4 for a section past the block.
  Refused(Int32)
}

///|
/// `decode_literals_header` on five bytes.
fn literals_header_of(
  b0 : Int32,
  b1 : Int32,
  b2 : Int32,
  b3 : Int32,
  b4 : Int32,
  avail : Int32,
  block_max : Int32,
) -> LiteralsParse where {
  proof_require: lit_header_pre(b0, b1, b2, b3, b4),
  proof_ensure: result => {
    lit_header_post(b0, b1, b2, b3, b4, avail, block_max, result)
  },
} {
  let literals_type = @proof_bits.low_bits(b0, 2)
  let size_format = @proof_bits.low_bits(@proof_bits.shr(b0, 2), 2)
  proof_assert literals_type == lit_type(b0)
  proof_assert size_format == lit_format(b0)
  // The header as one little-endian number, `lit_le`, holds Regenerated_Size
  // and, for compressed and treeless literals, Compressed_Size: each step
  // reads a field out of it byte by byte and asserts it is the field.
  let (header_len, regenerated, compressed) = if literals_type < 2 {
    // Raw or RLE: a 1-, 2- or 3-byte header with the regenerated size.
    let (header_len, regenerated) = if size_format == 1 {
      let regenerated = @proof_bits.shr(b0, 4) + @proof_bits.shl(b1, 4)
      proof_assert lit_width(b0) == 12 && lit_regen_shift(b0) == 16
      proof_assert @proof_fields.field_at(
        lit_le(b0, b1, b2, b3, b4),
        b0 % 16,
        regenerated + 4096 * (b2 + 256 * b3 + 65536 * b4),
        regenerated,
        b2 + 256 * b3 + 65536 * b4,
        16,
        4096,
      )
      proof_assert lit_le(b0, b1, b2, b3, b4) / 16 % 4096 == regenerated
      (2, regenerated)
    } else if size_format == 3 {
      let regenerated = @proof_bits.shr(b0, 4) +
        @proof_bits.shl(b1, 4) +
        @proof_bits.shl(b2, 12)
      proof_assert lit_width(b0) == 20 && lit_regen_shift(b0) == 16
      proof_assert @proof_fields.field_at(
        lit_le(b0, b1, b2, b3, b4),
        b0 % 16,
        regenerated + 1048576 * (b3 + 256 * b4),
        regenerated,
        b3 + 256 * b4,
        16,
        1048576,
      )
      proof_assert lit_le(b0, b1, b2, b3, b4) / 16 % 1048576 == regenerated
      (3, regenerated)
    } else {
      let regenerated = @proof_bits.shr(b0, 3)
      proof_assert lit_width(b0) == 5 && lit_regen_shift(b0) == 8
      proof_assert @proof_fields.field_at(
        lit_le(b0, b1, b2, b3, b4),
        b0 % 8,
        regenerated + 32 * (b1 + 256 * b2 + 65536 * b3 + 16777216 * b4),
        regenerated,
        b1 + 256 * b2 + 65536 * b3 + 16777216 * b4,
        8,
        32,
      )
      proof_assert lit_le(b0, b1, b2, b3, b4) / 8 % 32 == regenerated
      (1, regenerated)
    }
    proof_assert regenerated == lit_regenerated(b0, b1, b2, b3, b4)
    (header_len, regenerated, if literals_type == 0 { regenerated } else { 1 })
  } else if size_format == 2 {
    // Compressed or treeless: both sizes, in 14 bits each.
    let regenerated = @proof_bits.shr(b0, 4) +
      @proof_bits.shl(b1, 4) +
      @proof_bits.shl(@proof_bits.low_bits(b2, 2), 12)
    let compressed = @proof_bits.shr(b2, 2) + @proof_bits.shl(b3, 6)
    proof_assert lit_width(b0) == 14 && lit_regen_shift(b0) == 16
    proof_assert @proof_fields.field_at(
      lit_le(b0, b1, b2, b3, b4),
      b0 % 16,
      regenerated + 16384 * (b2 / 4 + 64 * b3 + 16384 * b4),
      regenerated,
      b2 / 4 + 64 * b3 + 16384 * b4,
      16,
      16384,
    )
    proof_assert lit_le(b0, b1, b2, b3, b4) / 16 % 16384 == regenerated
    proof_assert @proof_fields.field_at(
      lit_le(b0, b1, b2, b3, b4),
      b0 + 256 * b1 + 65536 * (b2 % 4),
      compressed + 16384 * b4,
      compressed,
      b4,
      262144,
      16384,
    )
    proof_assert lit_le(b0, b1, b2, b3, b4) / 262144 % 16384 == compressed
    proof_assert regenerated == lit_regenerated(b0, b1, b2, b3, b4)
    proof_assert compressed == lit_compressed_field(b0, b1, b2, b3, b4)
    (4, regenerated, compressed)
  } else if size_format == 3 {
    // 18 bits each.
    let regenerated = @proof_bits.shr(b0, 4) +
      @proof_bits.shl(b1, 4) +
      @proof_bits.shl(@proof_bits.low_bits(b2, 6), 12)
    let compressed = @proof_bits.shr(b2, 6) +
      @proof_bits.shl(b3, 2) +
      @proof_bits.shl(b4, 10)
    proof_assert lit_width(b0) == 18 && lit_regen_shift(b0) == 16
    proof_assert @proof_fields.field_at(
      lit_le(b0, b1, b2, b3, b4),
      b0 % 16,
      regenerated + 262144 * (b2 / 64 + 4 * b3 + 1024 * b4),
      regenerated,
      b2 / 64 + 4 * b3 + 1024 * b4,
      16,
      262144,
    )
    proof_assert lit_le(b0, b1, b2, b3, b4) / 16 % 262144 == regenerated
    proof_assert @proof_fields.field_at(
      lit_le(b0, b1, b2, b3, b4),
      b0 + 256 * b1 + 65536 * (b2 % 64),
      compressed + 262144 * 0,
      compressed,
      0,
      4194304,
      262144,
    )
    proof_assert lit_le(b0, b1, b2, b3, b4) / 4194304 % 262144 == compressed
    proof_assert regenerated == lit_regenerated(b0, b1, b2, b3, b4)
    proof_assert compressed == lit_compressed_field(b0, b1, b2, b3, b4)
    (5, regenerated, compressed)
  } else {
    // Size_Format 0 (one stream) or 1 (four): 10 bits each.
    let regenerated = @proof_bits.shr(b0, 4) +
      @proof_bits.shl(@proof_bits.low_bits(b1, 6), 4)
    let compressed = @proof_bits.shr(b1, 6) + @proof_bits.shl(b2, 2)
    proof_assert lit_width(b0) == 10 && lit_regen_shift(b0) == 16
    proof_assert @proof_fields.field_at(
      lit_le(b0, b1, b2, b3, b4),
      b0 % 16,
      regenerated + 1024 * (b1 / 64 + 4 * b2 + 1024 * b3 + 262144 * b4),
      regenerated,
      b1 / 64 + 4 * b2 + 1024 * b3 + 262144 * b4,
      16,
      1024,
    )
    proof_assert lit_le(b0, b1, b2, b3, b4) / 16 % 1024 == regenerated
    proof_assert @proof_fields.field_at(
      lit_le(b0, b1, b2, b3, b4),
      b0 + 256 * (b1 % 64),
      compressed + 1024 * (b3 + 256 * b4),
      compressed,
      b3 + 256 * b4,
      16384,
      1024,
    )
    proof_assert lit_le(b0, b1, b2, b3, b4) / 16384 % 1024 == compressed
    proof_assert regenerated == lit_regenerated(b0, b1, b2, b3, b4)
    proof_assert compressed == lit_compressed_field(b0, b1, b2, b3, b4)
    (3, regenerated, compressed)
  }
  proof_assert header_len == lit_header_len(b0)
  proof_assert compressed == lit_payload(b0, b1, b2, b3, b4)
  let block_type = if literals_type == 0 {
    RawLiterals
  } else if literals_type == 1 {
    RleLiterals
  } else if literals_type == 2 {
    CompressedLiterals
  } else {
    TreelessLiterals
  }
  if avail < header_len {
    Refused(1)
  } else if regenerated > block_max {
    Refused(2)
  } else if literals_type >= 2 && size_format != 0 && regenerated < 6 {
    Refused(3)
  } else if header_len + compressed > avail {
    Refused(4)
  } else {
    Parsed({ block_type, size_format, header_len, regenerated, compressed, })
  }
}
