// The frame header (RFC 8878 section 3.1.1.1): what a frame holds and the
// window it needs.

///|
/// A decoded frame header.
pub(all) struct FrameHeader {
  /// Single_Segment_Flag: the window is the content size.
  single_segment : Bool
  /// Content_Checksum_Flag.
  has_checksum : Bool
  /// Dictionary_ID; 0, the value for no dictionary, when the field is absent.
  dictionary_id : UInt32
  /// Frame_Content_Size, when the header has the field.
  content_size : UInt64?
  /// Window_Size in bytes: up to 2^41 + 7 * 2^38 from a window descriptor,
  /// or the content size of a single-segment frame.
  window_size : UInt64
  /// The header's length, descriptor included: 2 to 14 bytes.
  header_len : Int32
} derive(Eq, @debug.Debug)

///|
pub extend FrameHeader with Eq::{equal, not_equal}

///|
pub extend FrameHeader with @debug.Debug::{to_repr}

///|
/// The size of the Dictionary_ID field (Dictionary_ID_Flag).
fn dictionary_id_size(descriptor : Int32) -> Int32 {
  match descriptor & 3 {
    0 => 0
    1 => 1
    2 => 2
    _ => 4
  }
}

///|
/// The size of the Frame_Content_Size field (Frame_Content_Size_Flag): a
/// single-segment frame always has one.
fn content_size_size(descriptor : Int32) -> Int32 {
  match (descriptor >> 6) & 3 {
    0 => if (descriptor & 0x20) != 0 { 1 } else { 0 }
    1 => 2
    2 => 4
    _ => 8
  }
}

///|
/// The length of the frame header that starts with Frame_Header_Descriptor
/// `descriptor`, or why the header is refused: its reserved bit is set.
pub fn frame_header_len(descriptor : Int32) -> Result[Int32, String] {
  if (descriptor & 0x08) != 0 {
    Err("the frame header's reserved bit is set")
  } else {
    let window_descriptor_size = if (descriptor & 0x20) != 0 { 0 } else { 1 }
    Ok(
      1 +
      window_descriptor_size +
      dictionary_id_size(descriptor) +
      content_size_size(descriptor),
    )
  }
}

///|
/// The window a Window_Descriptor byte asks for (RFC 8878 section
/// 3.1.1.1.2): `2^(10 + Exponent)` and `Mantissa` eighths of it more.
/// Computed in 64 bits: up to 2^41 + 7 * 2^38.
pub fn window_size(window_descriptor : Int32) -> UInt64 {
  let base = 1UL << (10 + ((window_descriptor >> 3) & 31))
  base + (base >> 3) * (window_descriptor & 7).to_uint64()
}

///|
/// Parses the frame header at the start of `header`, which holds the
/// descriptor and the `frame_header_len` bytes it calls for; bytes past the
/// end read as zero. Refused only for the reserved bit: a dictionary or a
/// window too large is for the caller to judge.
pub fn parse_frame_header(
  header : ArrayView[Byte],
) -> Result[FrameHeader, String] {
  let descriptor = byte_at(header, 0)
  frame_header_len(descriptor).map(header_len => {
    let single_segment = (descriptor & 0x20) != 0
    let did_at = if single_segment { 1 } else { 2 }
    let did_size = dictionary_id_size(descriptor)
    let fcs_at = did_at + did_size
    let content_size = match content_size_size(descriptor) {
      0 => None
      2 => Some(le(header, fcs_at, 2) + 256)
      n => Some(le(header, fcs_at, n))
    }
    {
      single_segment,
      has_checksum: (descriptor & 0x04) != 0,
      dictionary_id: le(header, did_at, did_size).to_uint(),
      content_size,
      window_size: if single_segment {
        content_size.unwrap_or(0)
      } else {
        window_size(byte_at(header, 1))
      },
      header_len,
    }
  })
}
