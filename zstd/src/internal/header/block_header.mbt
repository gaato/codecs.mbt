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
  let last = (value & 1) != 0
  let size = (value >> 3) & 0x1FFFFF
  match (value >> 1) & 3 {
    0 => Ok({ last, block_type: Raw, size, })
    1 => Ok({ last, block_type: Rle, size, })
    2 => Ok({ last, block_type: Compressed, size, })
    _ => Err("a block of the reserved type")
  }
}

///|
/// Checks the block against `block_max`, Block_Maximum_Size: no block may
/// exceed it, and a compressed block holds at least one byte.
pub fn BlockHeader::check(
  self : BlockHeader,
  block_max : Int32,
) -> Result[BlockHeader, String] {
  if self.size > block_max {
    Err(
      match self.block_type {
        Raw => "a raw block larger than the block limit"
        Rle => "an RLE block larger than the block limit"
        Compressed => "a compressed block larger than the block limit"
      },
    )
  } else if self.block_type is Compressed && self.size == 0 {
    Err("an empty compressed block")
  } else {
    Ok(self)
  }
}
