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
  let prefix = transform_prefixes[transform]
  let kind = transform_types[transform].to_int()
  let suffix = transform_suffixes[transform]
  out.blit_from_bytesview(0, prefix)
  let mut n = prefix.length()
  let mut start = dictionary_offsets[length] + index * length
  let mut word_length = length
  if kind >= 1 && kind <= 9 {
    word_length = (length - kind).max(0)
  } else if kind >= 12 {
    let skip = kind - 11
    start += skip
    word_length = (length - skip).max(0)
  }
  out.blit_from_bytesview(n, dictionary[start:start + word_length])
  if kind == 10 {
    ferment(out, n, word_length, 0) |> ignore
  } else if kind == 11 {
    for i = 0; i < word_length; {
      continue i + ferment(out, n, word_length, i)
    }
  }
  n += word_length
  out.blit_from_bytesview(n, suffix)
  n + suffix.length()
}

///|
/// RFC 7932's `Ferment`: uppercases the character at `pos` of the word at
/// `out[start:start + length]` and returns its length in bytes.
fn ferment(
  out : FixedArray[Byte],
  start : Int32,
  length : Int32,
  pos : Int32,
) -> Int32 {
  let c = out[start + pos]
  if c < 192 {
    if c >= 97 && c <= 122 {
      out[start + pos] = c ^ 32
    }
    1
  } else if c < 224 {
    if pos + 1 < length {
      out[start + pos + 1] = out[start + pos + 1] ^ 32
    }
    2
  } else {
    if pos + 2 < length {
      out[start + pos + 2] = out[start + pos + 2] ^ 5
    }
    3
  }
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
