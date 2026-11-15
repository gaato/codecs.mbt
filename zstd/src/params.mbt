// The encoder's parameters for each level, transcribed from the reference
// implementation: facebook/zstd v1.5.7, lib/compress/clevels.h,
// `ZSTD_defaultCParameters` (BSD license; see NOTICE), levels 1 to 12 of
// its four tables and the row the negative levels start from. Tree rows use lazy2 with the same adjusted numbers:
// binary trees and optimal parsing are outside this encoder's scope.

///|
/// The match-finding strategy of a level, as `ZSTD_strategy` names it.
/// `Btlazy2` and `Btopt` appear in the tables for small inputs at levels 9
/// to 12; the encoder maps these to Lazy2, retaining their numeric row.
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
/// Double-fast additionally uses chain_log for its short hash table and
/// always hashes eight bytes in its long table.
priv struct Params {
  window_log : Int32
  chain_log : Int32
  hash_log : Int32
  search_log : Int32
  min_match : Int32
  target_length : Int32
  strategy : Strategy
  // Whether greedy, lazy and lazy2 search rows of tags instead of hash
  // chains; set by `encoder_params`.
  row_finder : Bool
}

///|
/// The highest level implemented; higher ones act as this one.
const MAX_LEVEL : Int32 = 12

///|
/// The level `Encoder` and `compress` use by default, as zstd's.
const DEFAULT_LEVEL : Int32 = 3

///|
/// The lowest level, zstd's `ZSTD_minCLevel()`: minus the largest block,
/// the most acceleration a target length can ask for.
const MIN_LEVEL : Int32 = -131072

///|
/// The level an encoder works at for `level`: 0 is the default, as in zstd,
/// and the rest is clamped to `MIN_LEVEL` to `MAX_LEVEL`.
fn effective_level(level : Int32) -> Int32 {
  if level == 0 {
    DEFAULT_LEVEL
  } else {
    level.clamp(min=MIN_LEVEL, max=MAX_LEVEL)
  }
}

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
    row_finder: false,
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
/// Row 0 of each table, "base for negative levels": fast rows that a
/// negative level gives its acceleration, as the target length.
let negative_rows : FixedArray[Params] = [
  row(19, 12, 13, 1, 6, 1, Fast),
  row(18, 12, 13, 1, 5, 1, Fast),
  row(17, 12, 12, 1, 5, 1, Fast),
  row(14, 12, 13, 1, 5, 1, Fast),
]

///|
/// The row of `table` for `level`, from `MIN_LEVEL` to 12 but not 0: a
/// negative level takes row 0 with its acceleration, `-level`, as the
/// target length, as `ZSTD_getCParams_internal` does.
fn level_row(table : Int32, level : Int32) -> Params {
  if level < 0 {
    { ..negative_rows[table], target_length: -level, }
  } else {
    level_tables[table][level - 1]
  }
}

///|
/// Whether a block's literals are Huffman-coded at all: not for a fast
/// level that accelerates, a negative one, as `ZSTD_literalsCompressionIsDisabled`
/// decides by default. No level from 1 up is such a row.
fn compresses_literals(params : Params) -> Bool {
  !(params.strategy is Fast && params.target_length > 0)
}

///|
/// The parameters for `level` (already made `effective_level`) and an input
/// of `size` bytes, or of unknown size, after a dictionary of `dict_size`
/// bytes (0 for none) put in the window before it.
///
/// As `ZSTD_getCParams` does, a known size picks the table for its size
/// class, and the window and tables then shrink as `ZSTD_adjustCParams`
/// does (without a dictionary); an unknown size
/// takes the table for large inputs as it is. The size is known only when
/// the caller states it, so the parameters, and the output, never depend on
/// how the input is split.
///
/// With a dictionary, as for zstd's dictionary copied into the window
/// (`ZSTD_cpm_noAttachDict`): the table is that for the input and the
/// dictionary together, or for the dictionary and 499 bytes when the size is
/// unknown (`ZSTD_getCParamRowSize` adds 500 to the unknown size,
/// `UINT64_MAX`, which wraps around to the dictionary and 499); a known size shrinks the window to
/// hold both, and the tables to the dictionary and the window
/// (`ZSTD_dictAndWindowLog`).
fn params_for(level : Int32, size : Int64?, dict_size~ : Int32 = 0) -> Params {
  let dict = dict_size.to_int64()
  let row_size = match size {
    Some(size) => Some(size + dict)
    None if dict > 0 => Some(499L + dict)
    None => None
  }
  let table = match row_size {
    Some(rsize) =>
      (if rsize <= 256 * 1024 { 1 } else { 0 }) +
      (if rsize <= 128 * 1024 { 1 } else { 0 }) +
      (if rsize <= 16 * 1024 { 1 } else { 0 })
    None => 0
  }
  let params = level_row(table, level)
  guard size is Some(size) else { return params }
  // The smallest log whose power of 2 holds `size` and the dictionary, at
  // least 6 (the smallest hash log), as `ZSTD_adjustCParams_internal`
  // computes it; sizes above 2^30 are not resized.
  let window_log = if size <= 1L << 30 && dict <= 1L << 30 {
    let total = size + dict
    let size_log = if total < 64 { 6 } else { 64 - (total - 1).clz() }
    params.window_log.min(size_log)
  } else {
    params.window_log
  }
  // The tables' log: the window's, or one that holds the dictionary and the
  // window when the window does not hold the dictionary and the input
  // (`ZSTD_dictAndWindowLog`; 31 is zstd's largest window log).
  let table_log = if dict == 0 || 1L << window_log >= dict + size {
    window_log
  } else if dict + (1L << window_log) >= 1L << 31 {
    31
  } else {
    64 - (dict + (1L << window_log) - 1).clz()
  }
  let bt_scale = match params.strategy {
    Btlazy2 | Btopt => 1
    _ => 0
  }
  let cycle_log = params.chain_log - bt_scale
  // Reduce the tables BEFORE restoring the frame's minimum windowLog.
  // Otherwise tiny inputs retain tables sized for 1 KiB instead of 64 B.
  // Dictionary tagging is inapplicable, and the row-finder hash cap (28
  // or more) cannot reduce any of the level 1..12 rows (at most 23).
  {
    ..params,
    window_log: window_log.max(10),
    hash_log: params.hash_log.min(table_log + 1),
    chain_log: params.chain_log - (cycle_log - table_log).max(0),
  }
}

///|
/// Selects by the adjusted row's strategy, and for greedy, lazy and lazy2
/// whether to search rows (windows over 2^14 bytes). Tree rows retain every numeric
/// parameter and use Lazy2 because binary trees/optimal parsing are outside
/// the supported strategies. Adjustment precedes mapping so the reference
/// tree cycle bit still governs the table sizes.
fn encoder_params(
  level : Int32,
  size : Int64?,
  dict_size~ : Int32 = 0,
) -> Params {
  let params = params_for(level, size, dict_size~)
  match params.strategy {
    Btlazy2 | Btopt => { ..params, strategy: Lazy2, }
    // As ZSTD_resolveRowMatchFinderMode decides by default, from the
    // adjusted window. Tree rows keep hash chains: the reference searches
    // them harder than a row's at most 64 candidates.
    Greedy | Lazy | Lazy2 => { ..params, row_finder: params.window_log > 14, }
    _ => params
  }
}
