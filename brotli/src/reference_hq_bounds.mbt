// Numeric backing storage, excluding runtime headers and garbage awaiting
// collection, as for the other resource bounds. Scratch is bounded by phase;
// the parser releases its nodes and archived matches before block splitting.

///|
fn hq_tree_bound(window_bits : Int32) -> Int64 {
  // Single 17-bit hash; two UInt32 children per window position; matches;
  // the static-word LUT, suffix groups and per-length dictionary candidates.
  (8L << window_bits) +
  4L * (1L << 17) +
  4L * 384L +
  2L * 32768L +
  4L * (31705L + 88L + 8L + 38L)
}

///|
fn hq_parse_bound(quality : Int32, block : Int64) -> Int64 {
  // Four packed node arrays, Float literal prefix sums, command/distance
  // costs, literal histogram, queue, original cache and second-pass model.
  let dp = 16L * (block + 1L) +
    4L * (block + 2L) +
    4L * (704L + 64L + 768L + 56L + 4L)
  if quality == 10 {
    dp + 12L
  } else {
    // At most 128 H10 and 64 raw-dictionary matches per position. Archive
    // capacity starts at 8*n UInt32s and doubles; reservation is 512 entries
    // before a position, and the final three positions have no candidates.
    dp + 4L * block + 4L * 512L * block + 4L * (704L + 64L + 256L + 256L)
  }
}

///|
fn hq_split_bound(n : Int64, alphabet : Int64, histograms : Int64) -> Int64 {
  let histogram = 4L * alphabet + 32L
  // Symbol vector (including its growing source array), ids, entropy-code
  // path costs and switch bitmap. Symbols use Int32 in this port.
  let find = 16L * n +
    n * ((histograms + 7L) / 8L) +
    histogram * (histograms + 1L) +
    8L * (alphabet + 1L) * histograms +
    4L * histograms
  // ClusterBlocks can retain one histogram per initial block. Do not assume
  // the reference's heuristic expected count (16 per batch) is a hard cap.
  // Include doubled array capacities, lengths, symbols, remapping, all-pair
  // batch storage and the final queue, limited to 64 pairs per histogram.
  let cluster = 16L * n +
    (histogram + 64L) * n +
    32L * (64L * n + 1L) +
    66L * histogram +
    4L * 4L * 64L +
    32L * 2049L
  find.max(cluster)
}

///|
fn hq_coding_bound(meta : Int64, commands : Int64) -> Int64 {
  let lit_histogram = 4L * 256L + 32L
  let cmd_histogram = 4L * 704L + 32L
  let dist_histogram = 4L * 544L + 32L
  // Completed splits: at most 256 types and one run per symbol; two run
  // arrays can each have twice their length in capacity. Original symbol
  // arrays may remain live while the next split is constructed.
  let splits = 16L * (meta + 2L * commands) +
    256L * (lit_histogram + cmd_histogram + dist_histogram) +
    12L * (meta + 2L * commands)
  let partition = hq_split_bound(meta, 256L, 100L)
    .max(hq_split_bound(commands, 704L, 50L))
    .max(hq_split_bound(commands, 544L, 50L))
  // Context clustering: literal input/output copies, all retained command
  // and distance histograms, sizes/maps/remapping and the capped pair queue.
  let contexts = 2L * 16384L * lit_histogram +
    256L * cmd_histogram +
    1024L * dist_histogram +
    32L * (64L * 16384L + 1L) +
    32L * 16384L +
    2L * lit_histogram +
    32L * 2049L
  // Huffman trees: depths/bits per final histogram, code construction and
  // context-map MTF/RLE buffers. These are independent of block length.
  let trees = 8L * 256L * (256L + 704L + 520L) +
    16L * (16384L + 1024L) +
    64L * 704L +
    4096L
  splits + partition.max(contexts).max(trees)
}

///|
fn hq_encoder_bound(quality : Int32, window_bits : Int32) -> Int64 {
  let w = window_bits.clamp(min=10, max=24)
  let window = 1L << w
  let block = ref_input_block(quality, w).to_int64()
  let meta = ref_max_meta(quality, w).to_int64()
  let commands = meta / 8L + block / 2L + 2L
  let ring = 2L * window.max(block)
  let retained = window -
    16L +
    meta +
    524296L +
    524288L +
    ring +
    4L * (meta + 512L) +
    80L * commands +
    encoder_fixed_memory(w).to_int64() +
    80L +
    hq_tree_bound(w)
  retained + hq_parse_bound(quality, block).max(hq_coding_bound(meta, commands))
}
