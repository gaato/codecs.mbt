// The encoder's parameters for each level, transcribed from the reference
// implementation: facebook/zstd v1.5.7, lib/compress/clevels.h,
// `ZSTD_defaultCParameters` (BSD license; see NOTICE), levels 1 to 12 of
// its four tables. P3 uses fast and the level-2 row for levels 3..12;
// the other rows remain here for the later dedicated strategies.

///|
/// The match-finding strategy of a level, as `ZSTD_strategy` names it.
/// `Btlazy2` and `Btopt` appear in the tables for small inputs at levels 9
/// to 12. P3 maps every requested strategy to fast with level-2 parameters.
#warnings("-unused_constructor")
priv enum Strategy {
  Fast
  Dfast
  Greedy
  Lazy
  Lazy2
  Btlazy2
  Btopt
}

///|
/// One row of `ZSTD_defaultCParameters`: the logs of the window, the chain
/// table and the hash table, the search depth (log), the shortest match,
/// the target length and the strategy. Fast reads window_log, hash_log,
/// min_match (hash width) and target_length (acceleration).
#warnings("-unused_field")
priv struct Params {
  window_log : Int32
  chain_log : Int32
  hash_log : Int32
  search_log : Int32
  min_match : Int32
  target_length : Int32
  strategy : Strategy
}

///|
/// The highest level implemented; higher ones act as this one.
const MAX_LEVEL : Int32 = 12

///|
/// The level `Encoder` and `compress` use by default, as zstd's.
const DEFAULT_LEVEL : Int32 = 3

///|
fn row(
  window_log : Int32,
  chain_log : Int32,
  hash_log : Int32,
  search_log : Int32,
  min_match : Int32,
  target_length : Int32,
  strategy : Strategy,
) -> Params {
  {
    window_log,
    chain_log,
    hash_log,
    search_log,
    min_match,
    target_length,
    strategy,
  }
}

///|
/// The four tables, each for levels 1 to 12 (index `level - 1`): for any
/// input larger than 256 KiB or of unknown size, and for inputs of at most
/// 256 KiB, 128 KiB and 16 KiB.
let level_tables : FixedArray[FixedArray[Params]] = [
  [
    row(19, 13, 14, 1, 7, 0, Fast),
    row(20, 15, 16, 1, 6, 0, Fast),
    row(21, 16, 17, 1, 5, 0, Dfast),
    row(21, 18, 18, 1, 5, 0, Dfast),
    row(21, 18, 19, 3, 5, 2, Greedy),
    row(21, 18, 19, 3, 5, 4, Lazy),
    row(21, 19, 20, 4, 5, 8, Lazy),
    row(21, 19, 20, 4, 5, 16, Lazy2),
    row(22, 20, 21, 4, 5, 16, Lazy2),
    row(22, 21, 22, 5, 5, 16, Lazy2),
    row(22, 21, 22, 6, 5, 16, Lazy2),
    row(22, 22, 23, 6, 5, 32, Lazy2),
  ],
  [
    row(18, 13, 14, 1, 6, 0, Fast),
    row(18, 14, 14, 1, 5, 0, Dfast),
    row(18, 16, 16, 1, 4, 0, Dfast),
    row(18, 16, 17, 3, 5, 2, Greedy),
    row(18, 17, 18, 5, 5, 2, Greedy),
    row(18, 18, 19, 3, 5, 4, Lazy),
    row(18, 18, 19, 4, 4, 4, Lazy),
    row(18, 18, 19, 4, 4, 8, Lazy2),
    row(18, 18, 19, 5, 4, 8, Lazy2),
    row(18, 18, 19, 6, 4, 8, Lazy2),
    row(18, 18, 19, 5, 4, 12, Btlazy2),
    row(18, 19, 19, 7, 4, 12, Btlazy2),
  ],
  [
    row(17, 12, 13, 1, 6, 0, Fast),
    row(17, 13, 15, 1, 5, 0, Fast),
    row(17, 15, 16, 2, 5, 0, Dfast),
    row(17, 17, 17, 2, 4, 0, Dfast),
    row(17, 16, 17, 3, 4, 2, Greedy),
    row(17, 16, 17, 3, 4, 4, Lazy),
    row(17, 16, 17, 3, 4, 8, Lazy2),
    row(17, 16, 17, 4, 4, 8, Lazy2),
    row(17, 16, 17, 5, 4, 8, Lazy2),
    row(17, 16, 17, 6, 4, 8, Lazy2),
    row(17, 17, 17, 5, 4, 8, Btlazy2),
    row(17, 18, 17, 7, 4, 12, Btlazy2),
  ],
  [
    row(14, 14, 15, 1, 5, 0, Fast),
    row(14, 14, 15, 1, 4, 0, Fast),
    row(14, 14, 15, 2, 4, 0, Dfast),
    row(14, 14, 14, 4, 4, 2, Greedy),
    row(14, 14, 14, 3, 4, 4, Lazy),
    row(14, 14, 14, 4, 4, 8, Lazy2),
    row(14, 14, 14, 6, 4, 8, Lazy2),
    row(14, 14, 14, 8, 4, 8, Lazy2),
    row(14, 15, 14, 5, 4, 8, Btlazy2),
    row(14, 15, 14, 9, 4, 8, Btlazy2),
    row(14, 15, 14, 3, 4, 12, Btopt),
    row(14, 15, 14, 4, 3, 24, Btopt),
  ],
]

///|
/// The parameters for `level` (already clamped to 1..=12) and an input of
/// `size` bytes, or of unknown size.
///
/// As `ZSTD_getCParams` does, a known size picks the table for its size
/// class, and the window then shrinks to the smallest power of 2 that holds
/// the input (at least 1 KiB), as `ZSTD_adjustCParams` does; an unknown size
/// takes the table for large inputs as it is. The size is known only when
/// the caller states it, so the parameters, and the output, never depend on
/// how the input is split.
fn params_for(level : Int32, size : Int64?) -> Params {
  guard size is Some(size) else { return level_tables[0][level - 1] }
  let table = (if size <= 256 * 1024 { 1 } else { 0 }) +
    (if size <= 128 * 1024 { 1 } else { 0 }) +
    (if size <= 16 * 1024 { 1 } else { 0 })
  let params = level_tables[table][level - 1]
  // The smallest log whose power of 2 holds `size`, at least 6 (the
  // smallest hash log), as `ZSTD_adjustCParams_internal` computes it; sizes
  // above 2^30 are not resized.
  guard size <= 1L << 30 else { return params }
  let size_log = if size < 64 { 6 } else { 64 - (size - 1).clz() }
  { ..params, window_log: params.window_log.min(size_log).max(10), }
}
