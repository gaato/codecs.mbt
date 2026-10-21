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
) -> Int32 where {
  proof_require: distance_code_pre(code, npostfix, ndirect),
  proof_ensure: result => {
    result == spec_extra_bits(code, npostfix, ndirect) &&
    0 <= result &&
    result <= 24
  },
} {
  let c = code - 16 - ndirect
  if c < 0 {
    0
  } else {
    1 + @proof_bits.shr(c, npostfix + 1)
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
) -> Int32? where {
  proof_require: distance_pre(code, extra, npostfix, ndirect),
  proof_ensure: result => {
    distance_post(
      code, extra, npostfix, ndirect, last1, last2, last3, last4, result,
    )
  },
} {
  proof_assert distance_code_pre(code, npostfix, ndirect)
  proof_assert 0 <= code
  if code >= 16 + ndirect {
    proof_assert spec_extra_bits(code, npostfix, ndirect) ==
      long_bits(code - 16 - ndirect, npostfix)
    proof_assert long_distance_pre(
      code - 16 - ndirect,
      extra,
      npostfix,
      ndirect,
    )
    Some(long_distance(code - 16 - ndirect, extra, npostfix, ndirect))
  } else if code >= 16 {
    Some(code - 15)
  } else {
    let d = short_code_distance(code, last1, last2, last3, last4)
    if d > 0 {
      Some(d)
    } else {
      None
    }
  }
}

///|
/// The distance of the code `c` places past the direct ones.
fn long_distance(
  c : Int32,
  extra : Int32,
  npostfix : Int32,
  ndirect : Int32,
) -> Int32 where {
  proof_require: long_distance_pre(c, extra, npostfix, ndirect),
  proof_ensure: result => {
    result == spec_long_distance(c, extra, npostfix, ndirect) &&
    result > ndirect
  },
} {
  let offset = long_offset(c, npostfix)
  let postfix = @proof_bits.low_bits(c, npostfix)
  // The shift's bound by cases on NPOSTFIX, each linear.
  proof_assert 0 <= offset + extra && offset + extra < 67108864
  proof_assert scaled_at(offset + extra, npostfix, 0, 1)
  proof_assert scaled_at(offset + extra, npostfix, 1, 2)
  proof_assert scaled_at(offset + extra, npostfix, 2, 4)
  proof_assert scaled_at(offset + extra, npostfix, 3, 8)
  @proof_bits.shl(offset + extra, npostfix) + postfix + ndirect + 1
}

///|
/// The offset of the code `c` places past the direct ones:
/// `((2 + (hcode & 1)) << ndistbits) - 4`.
fn long_offset(
  c : Int32,
  npostfix : Int32,
) -> Int32 where {
  proof_require: long_offset_pre(c, npostfix),
  proof_ensure: result => {
    result == spec_offset(c, npostfix) &&
    0 <= result &&
    result + @proof_bits.pow2(long_bits(c, npostfix)) <= 67108864
  },
} {
  let bits = 1 + @proof_bits.shr(c, npostfix + 1)
  let high = @proof_bits.low_bits(@proof_bits.shr(c, npostfix), 1)
  // The shift's bound: at most 24 extra bits, and `2 + high` 2 or 3.
  proof_assert 1 <= bits && bits <= 24
  proof_assert pow2_le_2_24(bits)
  proof_assert high == 0 || high == 1
  proof_assert (2 + high) * @proof_bits.pow2(bits) <= 3 * @proof_bits.pow2(bits)
  @proof_bits.shl(2 + high, bits) - 4
}

///|
/// The distance short code `code` (0 to 15) names, below one included.
fn short_code_distance(
  code : Int32,
  last1 : Int32,
  last2 : Int32,
  last3 : Int32,
  last4 : Int32,
) -> Int32 where {
  proof_require: 0 <= code && code < 16,
  proof_ensure: result => {
    result == short_distance(code, last1, last2, last3, last4)
  },
} {
  if code == 0 {
    last1
  } else if code == 1 {
    last2
  } else if code == 2 {
    last3
  } else if code == 3 {
    last4
  } else {
    let base = if code < 10 { last1 } else { last2 }
    let k = (code - 4) % 6
    let delta = @proof_bits.shr(k, 1) + 1
    if @proof_bits.low_bits(k, 1) == 0 {
      base - delta
    } else {
      base + delta
    }
  }
}
