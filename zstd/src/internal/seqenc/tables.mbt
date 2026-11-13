// The code tables of RFC 8878 section 3.1.1.3.2.1.1 and the default
// distributions of section 3.1.1.3.2.2.

///|
/// The largest literals length, match length and offset codes.
pub const MAX_LL_CODE : Int32 = 35

///|
/// The largest match length code.
pub const MAX_ML_CODE : Int32 = 52

///|
/// The largest offset code this decoder reads: windows are at most 1 << 30
/// bytes, and code 31 starts at offset 1 << 31 - 3.
pub const MAX_OF_CODE : Int32 = 30

///|
/// The largest offset code a table may give a probability to.
pub const MAX_OF_SYMBOL : Int32 = 31

///|
/// Literal length baselines, shared by encoder and decoder.
pub let ll_base : FixedArray[Int32] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20, 22, 24, 28, 32,
  40, 48, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536,
]

///|
/// Literal length extra bit counts.
pub let ll_bits : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7,
  8, 9, 10, 11, 12, 13, 14, 15, 16,
]

///|
/// Match length baselines.
pub let ml_base : FixedArray[Int32] = [
  3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24,
  25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 37, 39, 41, 43, 47, 51, 59, 67, 83,
  99, 131, 259, 515, 1027, 2051, 4099, 8195, 16387, 32771, 65539,
]

///|
/// Match length extra bit counts.
pub let ml_bits : FixedArray[Int32] = [
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14, 15,
  16,
]

///|
/// Predefined literal length distribution (accuracy log 6).
pub let ll_default : FixedArray[Int32] = [
  4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2,
  1, 1, 1, 1, 1, -1, -1, -1, -1,
]

///|
/// Predefined match length distribution (accuracy log 6).
pub let ml_default : FixedArray[Int32] = [
  1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
  1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1,
  -1,
]

///|
/// Predefined offset distribution (accuracy log 5).
pub let of_default : FixedArray[Int32] = [
  1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
  -1, -1, -1,
]
