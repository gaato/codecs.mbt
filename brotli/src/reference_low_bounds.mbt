// Capacities owned by the low-quality encoders, excluding runtime headers,
// caller buffers and garbage awaiting collection, as for the other bounds.

///|
fn low_tree_scratch() -> Int64 {
  // Huffman nodes, leaves/sorting, depth/bits, traversal stack and run vectors;
  // three final codes, their input histograms, and the code-header staging.
  4L * (3L * (2L * 704L + 1L) + 8L * 704L + 64L) +
  24L * 32L +
  8L * 2L * 704L +
  12L * (256L + 704L + 64L) +
  3L * 4096L
}

///|
fn low_encoder_bound(quality : Int32, window_bits : Int32) -> Int64 {
  let w = window_bits.clamp(min=10, max=24)
  let fixed = encoder_fixed_memory(w).to_int64() + 80L
  // LowTables' integer arrays. They are instantiated only for qualities 0..2.
  let tables = 4L * (4L * 704L + 2L * 18L + 2L * 704L + 2L * 64L)
  if quality <= 1 {
    let fragment = (1L << w).min(524288L)
    let hash = if quality == 0 {
      4L << (w.min(15) | 1)
    } else {
      4L << w.min(17)
    }
    let arena = tables +
      hash +
      4L * (3L * 128L + 2L * 256L + 128L) +
      520L +
      (if quality == 1 { 5L * fragment.min(131072L) } else { 0L })
    // Input/read staging, fragment-local rewrite buffer, pending output,
    // retained arena, and the separate Huffman-building phase.
    fixed +
    fragment +
    8L +
    524288L +
    (2L * fragment + 511L) +
    4L * (fragment + 512L) +
    arena +
    low_tree_scratch()
  } else {
    let meta = ref_max_meta(quality, w).to_int64()
    let ring = 2L * (1L << w).max(16384L)
    let commands = 2L * ((meta / 8L).min(12287L) + 8192L + 2L)
    fixed +
    (1L << w) -
    16L +
    meta +
    524296L +
    524288L +
    ring +
    4L * (meta + 512L) +
    40L * commands +
    262144L +
    (if quality == 2 { 98304L + tables } else { 0L }) +
    2L * meta +
    4104L +
    low_tree_scratch()
  }
}
