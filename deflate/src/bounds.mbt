///|
/// The most bytes `compress` writes for `n` bytes of input, at every level
/// and window, as libdeflate's `deflate_compress_bound` counts it: `n + 5 *
/// (n / 5,000 + 1) + 1`. A block never costs more than storing it, 5 bytes
/// for each stored block of up to 65,535, and every block but the last is
/// at least 5,000 bytes; a byte of padding ends the stream. An `Encoder`'s stream of `n` bytes is
/// within it too, plus 10 bytes for each `Flush`: its empty stored block
/// (`00 00 ff ff` after the bits that pad it) and a block more, since it ends
/// the block in progress early. A negative `n` counts as 0; past 2^62 the
/// result is the largest Int64.
pub fn compress_bound(n : Int64) -> Int64 {
  @deflater.stored_bound(n)
}

///|
/// What `Encoder::memory_usage` reports for an encoder of `level` (as for
/// `Encoder`), the same from the first step to the last, with a dictionary
/// or without: 542,516 bytes at levels 5 to 9, 542,172 at 2 to 4, 361,948 at
/// 1 and 131,077 at 0.
pub fn encoder_memory_bound(level~ : Int32 = 6) -> Int64 {
  @deflater.memory_bound(level)
}

///|
/// What `Decoder::memory_usage` reports, the same from the first step to
/// the last, with a dictionary or without: the 32 KiB window, the Huffman
/// tables of a block and their scratch space, 46,592 bytes.
pub fn decoder_memory_bound() -> Int64 {
  46592L
}
