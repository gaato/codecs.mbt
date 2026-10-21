// Static dictionary references (RFC 7932 section 8) and literal context
// modes (section 7.1).

///|
const NUM_TRANSFORMS : Int32 = 121

///|
/// The longest transformed word: a 24-byte word plus 13 added bytes.
const MAX_TRANSFORMED_WORD : Int32 = 37

///|
/// Writes word `index` of length `length` under transform `transform` into
/// `out`, and returns how many bytes it wrote.
fn transform_word(
  out : FixedArray[Byte],
  length : Int32,
  index : Int32,
  transform : Int32,
) -> Int32 {
  let kind = transform_types[transform].to_int()
  let mut start = dictionary_offsets[length] + index * length
  let mut word_length = length
  if kind >= 1 && kind <= 9 {
    word_length = (length - kind).max(0)
  } else if kind >= 12 {
    let skip = kind - 11
    start += skip
    word_length = (length - skip).max(0)
  }
  // A prefix and a suffix take at most 13 bytes together, so the word, at
  // most 24, fits in `out`'s MAX_TRANSFORMED_WORD bytes, as
  // `@transform.transform_into` requires (the test "transform_word: the
  // longest word under the longest transform fills the buffer" checks the
  // tables).
  @transform.transform_into(
    out,
    transform_prefixes[transform][:],
    dictionary[start:start + word_length],
    kind,
    transform_suffixes[transform][:],
  )
}

///|
/// The literal context ID of `mode` for the last two bytes `p1` and `p2`.
fn literal_context(mode : Int32, p1 : Int32, p2 : Int32) -> Int32 {
  match mode {
    0 => p1 & 0x3f
    1 => p1 >> 2
    2 => lut0[p1].to_int() | lut1[p2].to_int()
    _ => (lut2[p1].to_int() << 3) | lut2[p2].to_int()
  }
}
