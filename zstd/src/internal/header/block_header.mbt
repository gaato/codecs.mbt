// The block header (RFC 8878 section 3.1.1.2): three bytes in front of
// every block.

///|
/// Block_Type, less the reserved value.
pub(all) enum BlockType {
  Raw
  Rle
  Compressed
} derive(Eq, @debug.Debug)

///|
pub extend BlockType with Eq::{equal, not_equal}

///|
pub extend BlockType with @debug.Debug::{to_repr}

///|
/// A decoded block header.
pub(all) struct BlockHeader {
  /// Last_Block: the frame ends after this block.
  last : Bool
  block_type : BlockType
  /// Block_Size: the bytes that follow for a raw or compressed block, the
  /// bytes it decodes to for an RLE block.
  size : Int32
} derive(Eq, @debug.Debug)

///|
pub extend BlockHeader with Eq::{equal, not_equal}

///|
pub extend BlockHeader with @debug.Debug::{to_repr}

///|
/// Decodes `value`, the header's three bytes read little-endian, or refuses
/// the reserved block type.
pub fn parse_block_header(value : Int32) -> Result[BlockHeader, String] {
  match block_header_of(value & 0xFFFFFF) {
    Some(header) => Ok(header)
    None => Err("a block of the reserved type")
  }
}

///|
/// `parse_block_header` for a header of 24 bits, `None` for the reserved
/// type.
fn block_header_of(
  value : Int32,
) -> BlockHeader? where {
  proof_require: 0 <= value && value < 16777216,
  proof_ensure: result => block_header_post(value, result),
} {
  let last = @proof_bits.low_bits(value, 1) != 0
  let size = @proof_bits.shr(value, 3)
  let block_type = @proof_bits.low_bits(@proof_bits.shr(value, 1), 2)
  if block_type == 0 {
    Some({ last, block_type: Raw, size, })
  } else if block_type == 1 {
    Some({ last, block_type: Rle, size, })
  } else if block_type == 2 {
    Some({ last, block_type: Compressed, size, })
  } else {
    None
  }
}

///|
/// Checks the block against `block_max`, Block_Maximum_Size: no block may
/// exceed it, and a compressed block holds at least one byte.
pub fn BlockHeader::check(
  self : BlockHeader,
  block_max : Int32,
) -> Result[BlockHeader, String] {
  match block_refusal(self, block_max) {
    0 => Ok(self)
    1 =>
      Err(
        match self.block_type {
          Raw => "a raw block larger than the block limit"
          Rle => "an RLE block larger than the block limit"
          Compressed => "a compressed block larger than the block limit"
        },
      )
    _ => Err("an empty compressed block")
  }
}

///|
/// Why `BlockHeader::check` refuses `header`: 0 for not at all, 1 for a
/// block larger than `block_max`, 2 for an empty compressed block.
fn block_refusal(
  header : BlockHeader,
  block_max : Int32,
) -> Int32 where {
  proof_ensure: result => block_refusal_post(header, block_max, result),
} {
  if header.size > block_max {
    1
  } else {
    match header.block_type {
      Compressed => if header.size == 0 { 2 } else { 0 }
      _ => 0
    }
  }
}
