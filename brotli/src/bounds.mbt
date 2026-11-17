///|
/// The most bytes `compress` writes for `n` bytes of input, whatever the
/// window: the stream header, and for each meta-block of up to 64 KiB its
/// bytes and 5 more, since a meta-block that would come out larger than
/// its bytes is written uncompressed (4 header bytes) and the last one
/// then needs an empty last meta-block after it. An `Encoder`'s stream of
/// `n` bytes is within it too, plus 7 bytes for each `Flush` (the meta-block
/// it ends, and the empty metadata block that pads it to a byte). A
/// negative `n` counts as 0; past 2^62 the result is the largest Int64.
pub fn compress_bound(n : Int64) -> Int64 {
  let n = n.max(0L)
  // Past 2^62 the bound saturates at the largest Int64 rather than wrap.
  guard n <= 0x3FFFFFFFFFFFFFFFL else { return 0x7FFFFFFFFFFFFFFFL }
  n + 5L * (n / BLOCK_SIZE.to_int64() + 1L) + 2L
}

///|
/// The most `Decoder::memory_usage` reports for a decoder made with
/// `max_window_bits` (clamped to 10..24, as `Decoder` clamps it): the
/// window, the prefix code tables of the largest meta-block a stream may
/// declare (1,343,596 bytes) and the 27,793 bytes allocated with the
/// decoder. The static dictionary is shared and an LZ77 dictionary is the
/// caller's, so neither is counted.
pub fn decoder_memory_bound(max_window_bits~ : Int32 = 24) -> Int64 {
  (1L << max_window_bits.clamp(min=10, max=24)) +
  max_decoder_table_bytes().to_int64() +
  DECODER_FIXED_MEMORY.to_int64()
}

///|
/// The most `Encoder::memory_usage` reports for an encoder made with
/// `window_bits` (clamped to 10..24, as `Encoder` clamps it): its input
/// buffer at its largest, twice the most output that waits (the buffer
/// doubles), and what it allocates when it is made. A dictionary's index
/// is counted by `Dictionary::memory_usage`, not here.
/// `quality` and `size_hint` follow `Encoder`; a hint can select larger
/// hash tables at qualities 5 and 6. The reference path also reserves for
/// delayed commands, a 512 KiB read buffer, the reference ring, output and
/// 8 MiB of histogram and Huffman scratch. The bound is computed without
/// allocating these buffers.
pub fn encoder_memory_bound(
  window_bits~ : Int32 = 22,
  quality~ : Int32 = 4,
  size_hint? : Int64,
) -> Int64 {
  let quality = quality.clamp(min=0, max=11)
  if quality > 4 {
    let q = quality.min(9)
    let w = window_bits.clamp(min=10, max=24)
    let m = ref_max_meta(q, w).to_int64()
    let block = ref_input_block(q, w).to_int64()
    // Commands may exceed the delayed-command threshold by one input block.
    let ring = 1L << (w.max(if q == 9 { w.min(18).max(16) } else { 16 }) + 1)
    return (1L << w) -
      16L +
      m +
      524296L +
      524288L +
      ring +
      4L * (m + 512L) +
      ref_hasher_bound(q, w, size_hint.unwrap_or(0L)).to_int64() +
      80L * (m / 8L + block / 2L + 2L) +
      encoder_fixed_memory(w).to_int64() +
      80L +
      8388608L
  }
  let w = window_bits.clamp(min=10, max=24)
  ((1 << w) - 16).to_int64() +
  (1 << (w - 2)).max(BLOCK_SIZE).to_int64() +
  BLOCK_SIZE.to_int64() +
  2L * MAX_ENCODER_PENDING.to_int64() +
  encoder_fixed_memory(w).to_int64()
}

///|
/// The largest distance alphabet: NDIRECT 120, NPOSTFIX 3.
const MAX_DISTANCE_ALPHABET : Int32 = 16 + 120 + (48 << 3)

///|
/// The most bytes of prefix code tables a decoder holds: 256 trees of each
/// category, the block type and count codes, the context map code and the
/// code length code, at 2 bytes an entry.
fn max_decoder_table_bytes() -> Int32 {
  let entries = 256 *
    (
      max_table_size(NUM_LITERALS) +
      max_table_size(MAX_ALPHABET) +
      max_table_size(MAX_DISTANCE_ALPHABET)
    ) +
    3 * (max_table_size(258) + max_table_size(@rules.NUM_BLOCK_COUNT_CODES)) +
    max_table_size(256 + 16) +
    max_table_size(18)
  2 * entries
}

///|
/// What a decoder allocates when it is made (RESOURCE_BOUNDS.md, "Fixed
/// per decoder").
const DECODER_FIXED_MEMORY : Int32 = 27793

///|
/// The most output an encoder holds back: one meta-block's, at most its
/// 64 KiB of input and 64 bytes.
const MAX_ENCODER_PENDING : Int32 = BLOCK_SIZE + 64

///|
/// What an encoder allocates when it is made: the hash table, and the
/// meta-block's buffers with the distance ring (RESOURCE_BOUNDS.md, "Fixed
/// per encoder").
fn encoder_fixed_memory(window_bits : Int32) -> Int32 {
  (16 << window_bits.min(15)) + 351628
}
