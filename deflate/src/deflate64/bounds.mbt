///|
/// Fixed element-payload bytes held by `Decoder`: its 64 KiB history window,
/// Huffman tables, their construction scratch and the unfinished input unit.
/// Excludes runtime object headers and the caller's buffers.
pub fn decoder_memory_bound() -> Int64 {
  79384L
}
