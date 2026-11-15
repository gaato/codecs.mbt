///|
/// The most bytes `compress` or an `Encoder` writes for `n` bytes of
/// input, at any level and with any dictionary: the input, 3 bytes for each
/// block (a block is never larger than its bytes stored raw, and is at
/// least 1 KiB, the smallest window, unless it is the last), one block for
/// no input, the magic number and the longest frame header (4 + 14, with a
/// 4-byte dictionary id and an 8-byte content size) and the 4-byte
/// checksum. Each `Flush` that ends a block early adds 3 bytes. Like
/// `ZSTD_compressBound`, it allows for blocks smaller than `compress` writes
/// (its blocks are 128 KiB once the input is), so that it holds for an
/// `Encoder` whose parameters choose a small window. A negative `n` counts
/// as 0; past 2^62 the result is the largest Int64.
pub fn compress_bound(n : Int64) -> Int64 {
  let n = n.max(0L)
  // Past 2^62 the bound saturates at the largest Int64 rather than wrap.
  guard n <= 0x3FFFFFFFFFFFFFFFL else { return 0x7FFFFFFFFFFFFFFFL }
  n + 3L * (n / 1024L + 1L) + 22L
}

///|
/// The most `Decoder::memory_usage` reports for a decoder made with
/// `max_window_bits` (clamped to 10..30, as `Decoder` clamps it): the
/// window, a compressed block and its literals, and the 13,156 bytes of
/// tables made with the decoder. A dictionary is the caller's and is not
/// counted.
pub fn decoder_memory_bound(max_window_bits~ : Int32 = 27) -> Int64 {
  (1L << max_window_bits.clamp(min=10, max=30)) +
  2L * MAX_BLOCK_SIZE.to_int64() +
  DECODER_TABLE_BYTES.to_int64()
}

///|
/// The most `Encoder::memory_usage` reports for an encoder made with
/// these options, whatever the input and however it is split: what the
/// level's parameters (chosen for `content_size` and a dictionary of
/// `dictionary_len` bytes, as `Encoder` chooses them) allocate, with the
/// room its buffers may double into. `level` is as for `Encoder`.
pub fn encoder_memory_bound(
  level~ : Int32 = DEFAULT_LEVEL,
  content_size? : Int64,
  dictionary_len~ : Int32 = 0,
) -> Int64 {
  let content_size = match content_size {
    Some(size) if size >= 0 => Some(size)
    _ => None
  }
  let dictionary_len = dictionary_len.clamp(min=0, max=MAX_ENCODER_DICTIONARY)
  let params = encoder_params(
    effective_level(level),
    content_size,
    dict_size=dictionary_len,
  )
  memory_bound_of(params, dictionary_len)
}

///|
/// The tables a decoder is made with: the Huffman table and its scratch,
/// the three FSE tables and their scratch (RESOURCE_BOUNDS.md, "Fixed per
/// decoder").
const DECODER_TABLE_BYTES : Int32 = 13156

///|
/// The most bytes the encoder's output writer holds at once: the magic
/// number and the longest frame header (4 + 14), one block (3 + 128 KiB)
/// and the checksum (4).
const ENCODER_PENDING_MAX : Int32 = 4 + 14 + 3 + MAX_BLOCK_SIZE + 4

///|
/// The fixed parts of an encoder that do not depend on its parameters: the
/// literals writer and the sequence tables' writer.
let encoder_fixed_bytes : Int64 = (LiteralsWriter::new(compress=true).memory_usage() +
@seqenc.Writer().memory_usage()).to_int64()

///|
/// What an encoder with `params` and a dictionary of `dictionary_len` bytes
/// may hold, as RESOURCE_BOUNDS.md gives it: the input in shared history
/// (the dictionary held as part of its window), waiting output, the match
/// tables, sequence arrays and scratch, and both entropy coders. Packer
/// capacities include doubling and 5 bytes past the bytes written: a write
/// reserves at most the bytes it moves.
fn memory_bound_of(params : Params, dictionary_len : Int32) -> Int64 {
  let reach = (1L << params.window_log) + dictionary_len.to_int64()
  let block = MAX_BLOCK_SIZE.to_int64()
  2L * (ENCODER_PENDING_MAX + 5).to_int64() +
  encoder_fixed_bytes +
  2L * 2L * (512L + 5L) +
  2L * reach +
  reach.min(block) +
  4L * (1L << params.hash_log) +
  (if params.strategy is Fast {
    12L
  } else if params.row_finder {
    1L << params.hash_log
  } else {
    4L * (1L << params.chain_log)
  }) +
  block +
  12L * (block / 3L) +
  12L +
  3L * 2L * (512L + 5L) +
  2L * ((1L << 19) + 5L)
}
