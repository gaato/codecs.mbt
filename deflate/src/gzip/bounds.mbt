///|
/// The most bytes `compress` writes for `n` bytes of input with `header`:
/// the raw DEFLATE bound (`@deflate.compress_bound`), the header (10 bytes,
/// and its extra field, name and comment) and the 8-byte trailer. An
/// `Encoder`'s member of `n` bytes is within it too, plus 10 bytes for each
/// `Flush`. Past 2^62 the result is the largest Int64.
pub fn compress_bound(n : Int64, header? : Header) -> Int64 {
  let raw = @deflater.stored_bound(n)
  if raw == 0x7FFFFFFFFFFFFFFFL {
    raw
  } else {
    raw + header_size(header).to_int64() + 8L
  }
}

///|
/// What `Encoder::memory_usage` reports for an encoder of `level` with
/// `header`: the raw DEFLATE encoder's (`@deflate.encoder_memory_bound`)
/// and the header's bytes.
pub fn encoder_memory_bound(level~ : Int32 = 6, header? : Header) -> Int64 {
  @deflater.memory_bound(level) + header_size(header).to_int64()
}

///|
/// The most `Decoder::memory_usage` reports for a decoder made with these
/// options: the raw DEFLATE decoder's 46,592 bytes, and `max_header_bytes`
/// for the header's fields when they are kept.
pub fn decoder_memory_bound(
  keep_header~ : Bool = true,
  max_header_bytes~ : Int32 = 65536,
) -> Int64 {
  46592L + (if keep_header { max_header_bytes.max(0).to_int64() } else { 0L })
}

///|
/// The bytes of the header `Encoder` writes for `header`: the fixed 10, the
/// extra field with its 2-byte length, and the name and the comment with
/// their terminating zeros.
fn header_size(header : Header?) -> Int32 {
  match header {
    None => 10
    Some(h) =>
      10 +
      (match h.extra {
        Some(e) => 2 + e.length()
        None => 0
      }) +
      (match h.name {
        Some(n) => n.length() + 1
        None => 0
      }) +
      (match h.comment {
        Some(c) => c.length() + 1
        None => 0
      })
  }
}
