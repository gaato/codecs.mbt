// What a frame's header says, and the constants of the frame format
// (doc/lz4_Frame_format.md of lz4 1.10.0).

///|
/// The magic number of an LZ4 frame.
const FRAME_MAGIC : UInt32 = 0x184D2204

///|
/// The magic number of a legacy frame, which `lz4 -l` writes.
const LEGACY_MAGIC : UInt32 = 0x184C2102

///|
/// The size a legacy block decodes to at most.
const LEGACY_BLOCK : Int32 = 8388608

///|
/// The longest compressed legacy block: `LZ4_COMPRESSBOUND(8 MiB)`. A larger
/// value where a block size would be cannot begin a block.
const LEGACY_BOUND : Int32 = 8388608 + 8388608 / 255 + 16

///|
/// The most a match reaches back.
const MAX_DISTANCE : Int32 = 65535

///|
/// The largest uncompressed size of a frame's blocks, from its header.
#derive(Eq, @debug.Debug)
pub(all) enum BlockSize {
  Max64KiB
  Max256KiB
  Max1MiB
  Max4MiB
}

///|
/// Compares two block sizes.
pub extend BlockSize with Eq::{equal, not_equal}

///|
/// Shows the block size by its name, for tests and messages.
pub extend BlockSize with @debug.Debug::{to_repr}

///|
/// The size in bytes.
pub fn BlockSize::bytes(self : BlockSize) -> Int32 {
  match self {
    Max64KiB => 65536
    Max256KiB => 262144
    Max1MiB => 1048576
    Max4MiB => 4194304
  }
}

///|
/// The header's code for the size: 4 to 7.
fn BlockSize::code(self : BlockSize) -> Int32 {
  match self {
    Max64KiB => 4
    Max256KiB => 5
    Max1MiB => 6
    Max4MiB => 7
  }
}

///|
/// What a frame's header says. A legacy frame (`lz4 -l`) has blocks of 8 MiB
/// and none of the other fields: its `block_size` is None.
#derive(Eq, @debug.Debug)
pub struct FrameInfo {
  /// The largest uncompressed size of a block, None for a legacy frame.
  block_size : BlockSize?
  /// Whether a block's matches may reach into the blocks before it.
  linked : Bool
  /// Whether each block carries the XXH32 of its stored bytes.
  block_checksum : Bool
  /// Whether the frame ends with the XXH32 of its content.
  content_checksum : Bool
  /// The content's size in bytes, when the header gives it.
  content_size : UInt64?
  /// The dictionary the frame was written with, when the header names one.
  dictionary_id : UInt32?
  /// Whether this is a legacy frame.
  legacy : Bool
}

///|
/// Compares two frame headers, field by field.
pub extend FrameInfo with Eq::{equal, not_equal}

///|
/// Shows the frame header as its fields, for tests and messages.
pub extend FrameInfo with @debug.Debug::{to_repr}
