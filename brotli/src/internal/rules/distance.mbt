// Distance codes (RFC 7932 section 4): the parameters of the distance
// alphabet, and the distance each code names.

///|
/// NDIRECT from the meta-block header's NPOSTFIX (0 to 3) and its 4-bit
/// field, which holds NDIRECT >> NPOSTFIX (section 9.2).
pub fn direct_distance_codes(npostfix : Int32, field : Int32) -> Int32 {
  field << npostfix
}

///|
/// The size of the distance alphabet: 16 short codes, NDIRECT direct codes
/// and `48 << NPOSTFIX` codes with extra bits.
pub fn distance_alphabet_size(npostfix : Int32, ndirect : Int32) -> Int32 {
  16 + ndirect + (48 << npostfix)
}

///|
/// How many extra bits follow distance code `code`: none below
/// `16 + ndirect`, and `1 + ((code - ndirect - 16) >> (npostfix + 1))` from
/// there, at most 24.
pub fn distance_extra_bits(
  code : Int32,
  npostfix : Int32,
  ndirect : Int32,
) -> Int32 {
  let c = code - 16 - ndirect
  if c < 0 {
    0
  } else {
    1 + (c >> (npostfix + 1))
  }
}

///|
/// The distance distance code `code` names, with `extra` the value of its
/// `distance_extra_bits` and `last1` to `last4` the last four distances,
/// latest first: a short code (0 to 15) against those, a direct code
/// (16 to 15 + NDIRECT), or a code with extra bits. `None` when a short code
/// names a distance below one. `code` ranges over the distance alphabet.
pub fn distance(
  code : Int32,
  extra : Int32,
  npostfix~ : Int32,
  ndirect~ : Int32,
  last1~ : Int32,
  last2~ : Int32,
  last3~ : Int32,
  last4~ : Int32,
) -> Int32? {
  if code >= 16 + ndirect {
    let c = code - 16 - ndirect
    let bits = 1 + (c >> (npostfix + 1))
    let offset = ((2 + ((c >> npostfix) & 1)) << bits) - 4
    let postfix = c & ((1 << npostfix) - 1)
    return Some(((offset + extra) << npostfix) + postfix + ndirect + 1)
  }
  if code >= 16 {
    return Some(code - 15)
  }
  let d = match code {
    0 => last1
    1 => last2
    2 => last3
    3 => last4
    _ => {
      let base = if code < 10 { last1 } else { last2 }
      let k = (code - 4) % 6
      let delta = (k >> 1) + 1
      if (k & 1) == 0 {
        base - delta
      } else {
        base + delta
      }
    }
  }
  if d > 0 {
    Some(d)
  } else {
    None
  }
}
