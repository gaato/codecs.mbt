// Length codes by table and highest bit, as zstd's ZSTD_LLcode and
// ZSTD_MLcode compute them: below the point where every code's baseline is
// a power of two (64 literals, 131 matched bytes), one table lookup;
// above it, the position of the highest set bit plus a constant.

///|
/// Literals lengths below this have their code in `ll_code_table`.
const LL_TABLE_SIZE : Int32 = 64

///|
/// Match lengths below this have their code in `ml_code_table`: 128 above
/// the minimum match length 3.
const ML_TABLE_SIZE : Int32 = 131

///|
/// Literals length codes of 0..63, from the baselines.
let ll_code_table : FixedArray[Int32] = FixedArray::makei(LL_TABLE_SIZE, v => {
  length_code(v, ll_base)
})

///|
/// Match length codes of 0..130, from the baselines. Values below the
/// minimum match length have code 0, as `length_code` gives them.
let ml_code_table : FixedArray[Int32] = FixedArray::makei(ML_TABLE_SIZE, v => {
  length_code(v, ml_base)
})

///|
/// Literals length code of `value` (0..=131072), equal to
/// `length_code(value, ll_base)`. From 64 on, code 19 + k has baseline
/// 2^k, so the code is 19 plus the highest set bit; the largest code is 35.
pub fn ll_code(value : Int32) -> Int32 {
  if value < LL_TABLE_SIZE {
    // 0 <= value < 64, the table's length.
    table_get(ll_code_table, value)
  } else {
    (19 + 31 - value.clz()).min(MAX_LL_CODE)
  }
}

///|
/// Match length code of `value` (0..=131072), equal to
/// `length_code(value, ml_base)`. From 131 on, code 36 + k has baseline
/// 2^k + 3, so the code is 36 plus the highest set bit of `value - 3`; the
/// largest code is 52.
pub fn ml_code(value : Int32) -> Int32 {
  if value < ML_TABLE_SIZE {
    // 0 <= value < 131, the table's length.
    table_get(ml_code_table, value)
  } else {
    (36 + 31 - (value - 3).clz()).min(MAX_ML_CODE)
  }
}

///|
/// Callers pass an index they have checked against the table's length.
#cfg(any(target="native", target="wasm"))
#inline
fn table_get(table : FixedArray[Int32], i : Int32) -> Int32 {
  table.unsafe_get(i)
}

///|
#cfg(not(any(target="native", target="wasm")))
#inline
fn table_get(table : FixedArray[Int32], i : Int32) -> Int32 {
  table[i]
}
