///|
/// The most bytes `compress` writes for `n` bytes of input, at every level
/// and window: the raw DEFLATE bound (`@deflate.compress_bound`) and 10
/// bytes, the 2-byte header, the 4-byte id of a dictionary, which the
/// bound allows for whether or not there is one, and the 4-byte Adler-32.
/// An `Encoder`'s stream of `n` bytes is within it too, plus 10 bytes for
/// each `Flush`. Past 2^62 the result is the largest Int64.
pub fn compress_bound(n : Int64) -> Int64 {
  let raw = @deflater.stored_bound(n)
  if raw == 0x7FFFFFFFFFFFFFFFL {
    raw
  } else {
    raw + 10L
  }
}

///|
/// An upper bound on `Encoder::memory_usage` for `level`: the raw
/// DEFLATE encoder's (`@deflate.encoder_memory_bound`), with a dictionary or
/// without.
pub fn encoder_memory_bound(level~ : Int32 = 6) -> Int64 {
  @deflater.memory_bound(level)
}

///|
/// What `Decoder::memory_usage` reports: the raw DEFLATE decoder's, 46,592
/// bytes, with a dictionary or without.
pub fn decoder_memory_bound() -> Int64 {
  46592L
}
