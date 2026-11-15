// Frames read without decoding them (RFC 8878 sections 3.1.1 and 3.1.2):
// what a frame header says, where a frame ends, and skippable frames, which
// carry the caller's bytes and which decoders pass over.

///|
/// The first magic number of skippable frames: the 16 numbers from it to
/// 0x184D2A5F all start one, their low four bits the frame's variant.
const SKIPPABLE_MAGIC : UInt32 = 0x184D2A50

///|
/// What a Zstandard frame's header says, as `inspect_frame` reads it.
#derive(Eq, @debug.Debug)
pub struct FrameInfo {
  /// Window_Size in bytes: the history a decoder keeps for the frame, from
  /// the window descriptor, or the content size of a single-segment frame.
  window_size : UInt64
  /// Frame_Content_Size, when the header has the field.
  content_size : UInt64?
  /// Dictionary_ID: the dictionary the frame needs, or 0 for none.
  dictionary_id : UInt32
  /// Content_Checksum_Flag: the frame ends with four bytes of XXH64.
  has_checksum : Bool
  /// Single_Segment_Flag: the window is the content size.
  single_segment : Bool
  /// The bytes before the first block: the magic number and the header, 6
  /// to 18.
  header_len : Int32
}

///|
/// Compares two frame headers read by `inspect_frame`, field by field.
pub extend FrameInfo with Eq::{equal, not_equal}

///|
/// Shows the frame header as its fields, for tests and messages.
pub extend FrameInfo with @debug.Debug::{to_repr}

///|
/// The frame at the start of some bytes, as `inspect_frame` sees it.
#non_exhaustive
#derive(Eq, @debug.Debug)
pub(all) enum Frame {
  /// A Zstandard frame, and what its header says.
  Zstd(FrameInfo)
  /// A skippable frame: its variant, 0 to 15 (the magic number's low four
  /// bits), and how many bytes of the caller's it holds after its 8-byte
  /// header.
  Skippable(variant~ : Int32, size~ : UInt32)
}

///|
/// Compares two frames read by `inspect_frame`, field by field.
pub extend Frame with Eq::{equal, not_equal}

///|
/// Shows the frame as its fields, for tests and messages.
pub extend Frame with @debug.Debug::{to_repr}

///|
/// `n` bytes from `at`, little-endian; the caller has checked they are there.
fn read_le(input : BytesView, at : Int32, n : Int32) -> UInt64 {
  let mut value = 0UL
  for i = n - 1; i >= 0; i = i - 1 {
    value = (value << 8) | input[at + i].to_uint64()
  }
  value
}

///|
fn truncated(what : String) -> @codec.CodecError {
  CodecError(Truncated, "the input ends inside \{what}")
}

///|
/// Reads the header of the frame at the start of `input` without decoding
/// it: a Zstandard frame's window, content size, dictionary and checksum
/// flag, or a skippable frame's variant and size. Only the header's bytes
/// are read.
///
/// Raises `Truncated` if `input` ends inside the header, and `Corrupt` if it
/// starts with neither magic number or the header's reserved bit is set. A
/// window or a dictionary is not judged here: `Decoder` judges those.
pub fn inspect_frame(input : BytesView) -> Frame raise @codec.CodecError {
  guard input.length() >= 4 else { raise truncated("a magic number") }
  let magic = read_le(input, 0, 4).to_uint()
  if (magic & 0xFFFFFFF0) == SKIPPABLE_MAGIC {
    guard input.length() >= 8 else {
      raise truncated("a skippable frame's header")
    }
    return Skippable(
      variant=(magic & 0xF).reinterpret_as_int(),
      size=read_le(input, 4, 4).to_uint(),
    )
  }
  guard magic == FRAME_MAGIC else {
    raise CodecError(Corrupt, "not a zstd frame")
  }
  guard input.length() >= 5 else { raise truncated("a frame header") }
  let len = match @header.frame_header_len(input[4].to_int()) {
    Ok(len) => len
    Err(message) => raise CodecError(Corrupt, message)
  }
  guard input.length() >= 4 + len else { raise truncated("a frame header") }
  let bytes = FixedArray::makei(len, i => input[4 + i])
  let header = match @header.parse_frame_header(bytes[:]) {
    Ok(header) => header
    Err(message) => raise CodecError(Corrupt, message)
  }
  Zstd({
    window_size: header.window_size,
    content_size: header.content_size,
    dictionary_id: header.dictionary_id,
    has_checksum: header.has_checksum,
    single_segment: header.single_segment,
    header_len: 4 + header.header_len,
  })
}

///|
/// The length of the frame at the start of `input`, a Zstandard frame or a
/// skippable one, found by reading its header and walking its block headers
/// (an RLE block holds one byte, a raw or compressed block its size) and its
/// checksum, without decoding anything; `input[frame_size(input):]` is what
/// follows the frame. As zstd's `ZSTD_findFrameCompressedSize`.
///
/// Raises `Truncated` if `input` ends inside the frame, and `Corrupt` for
/// what `inspect_frame` refuses and for a block of the reserved type. The
/// blocks' contents are not checked: `Decoder` does that.
pub fn frame_size(input : BytesView) -> Int64 raise @codec.CodecError {
  match inspect_frame(input) {
    Skippable(size~, ..) => {
      let total = 8L + size.to_int64()
      guard input.length().to_int64() >= total else {
        raise truncated("a skippable frame")
      }
      total
    }
    Zstd(info) => {
      let mut at = info.header_len
      for ;; {
        guard input.length() - at >= 3 else {
          raise truncated("a block header")
        }
        let block = match
          @header.parse_block_header(read_le(input, at, 3).to_int()) {
          Ok(block) => block
          Err(message) => raise CodecError(Corrupt, message)
        }
        let body = if block.block_type is Rle { 1 } else { block.size }
        guard input.length() - at - 3 >= body else {
          raise truncated("a block")
        }
        at += 3 + body
        if block.last {
          break
        }
      }
      if info.has_checksum {
        guard input.length() - at >= 4 else {
          raise truncated("the content checksum")
        }
        at += 4
      }
      at.to_int64()
    }
  }
}

///|
/// A skippable frame of `variant` (its low four bits are used) holding
/// `data`: the magic number `0x184D2A50 + variant`, the length of `data` in
/// four little-endian bytes, then `data`. Decoders skip it, so it carries
/// bytes of the caller's beside Zstandard frames, as the header of RFC
/// 9842's `dcz` coding does.
pub fn skippable_frame(variant : Int32, data : BytesView) -> Bytes {
  let magic = SKIPPABLE_MAGIC | (variant & 0xF).reinterpret_as_uint()
  let n = data.length().reinterpret_as_uint()
  let out = Buffer(size_hint=8 + data.length())
  out.write_uint_le(magic)
  out.write_uint_le(n)
  out.write_bytesview(data)
  out.to_bytes()
}

///|
/// The variant and the data of the skippable frame at the start of `input`,
/// a view into `input`. Raises `Truncated` if `input` ends inside the frame,
/// and `Corrupt` if it does not start with a skippable frame.
pub fn read_skippable_frame(
  input : BytesView,
) -> (Int32, BytesView) raise @codec.CodecError {
  match inspect_frame(input) {
    Skippable(variant~, size~) => {
      guard input.length().to_int64() - 8L >= size.to_int64() else {
        raise truncated("a skippable frame")
      }
      (variant, input[8:8 + size.reinterpret_as_int()])
    }
    _ => raise CodecError(Corrupt, "not a skippable frame")
  }
}
