// The jump table in front of four Huffman streams (RFC 8878 section
// 3.1.1.3.1.6): three 2-byte sizes, the fourth implied.

///|
/// The 2-byte little-endian value at `data[at]`; bytes past the end read as
/// zero.
pub fn le16(data : ArrayView[Byte], at : Int32) -> Int32 {
  byte_at(data, at) | (byte_at(data, at + 1) << 8)
}

///|
/// The four stream sizes, given `total`, the bytes of the jump table and
/// the streams together, and the three sizes the table holds. Refused when
/// the table does not fit or leaves the fourth stream no byte.
pub fn stream_sizes(
  total : Int32,
  size1 : Int32,
  size2 : Int32,
  size3 : Int32,
) -> Result[(Int32, Int32, Int32, Int32), String] {
  match fourth_stream_size(total, size1, size2, size3) {
    Some(size4) => Ok((size1, size2, size3, size4))
    None =>
      Err(
        if total < 10 {
          "four Huffman streams in fewer than 10 bytes"
        } else {
          "a Huffman jump table past its streams"
        },
      )
  }
}

///|
/// The size of the fourth stream, what the jump table and the other three
/// leave of `total`, when the streams fit and the fourth has a byte.
fn fourth_stream_size(
  total : Int32,
  size1 : Int32,
  size2 : Int32,
  size3 : Int32,
) -> Int32? where {
  proof_require: jump_table_pre(total, size1, size2, size3),
  proof_ensure: result => jump_table_post(total, size1, size2, size3, result),
} {
  let size4 = total - 6 - size1 - size2 - size3
  if total < 10 {
    None
  } else if size4 <= 0 {
    None
  } else {
    Some(size4)
  }
}

///|
/// `stream_sizes` for the jump table and streams in `data`.
pub fn parse_jump_table(
  data : ArrayView[Byte],
) -> Result[(Int32, Int32, Int32, Int32), String] {
  stream_sizes(data.length(), le16(data, 0), le16(data, 2), le16(data, 4))
}
