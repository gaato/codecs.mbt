///|
/// RFC 7932 section 4's table of short distance codes: which of the last
/// distances each code starts from (1 the last, 2 the second-to-last, ...)
/// and what it adds.
let short_code_table : Array[(Int32, Int32)] = [
  (1, 0),
  (2, 0),
  (3, 0),
  (4, 0),
  (1, -1),
  (1, 1),
  (1, -2),
  (1, 2),
  (1, -3),
  (1, 3),
  (2, -1),
  (2, 1),
  (2, -2),
  (2, 2),
  (2, -3),
  (2, 3),
]

///|
/// The distance code `dcode` names, written from section 4's pseudo-code.
fn reference_distance(
  dcode : Int32,
  dextra : Int32,
  npostfix : Int32,
  ndirect : Int32,
  last : Array[Int32],
) -> Int32? {
  let distance = if dcode < 16 {
    let (back, delta) = short_code_table[dcode]
    last[back - 1] + delta
  } else if dcode < 16 + ndirect {
    dcode - 15
  } else {
    let postfix_mask = (1 << npostfix) - 1
    let ndistbits = 1 + ((dcode - ndirect - 16) >> (npostfix + 1))
    let hcode = (dcode - ndirect - 16) >> npostfix
    let lcode = (dcode - ndirect - 16) & postfix_mask
    let offset = ((2 + (hcode & 1)) << ndistbits) - 4
    ((offset + dextra) << npostfix) + lcode + ndirect + 1
  }
  if distance >= 1 {
    Some(distance)
  } else {
    None
  }
}

///|
fn ref_extra_bits(dcode : Int32, npostfix : Int32, ndirect : Int32) -> Int32 {
  if dcode < 16 + ndirect {
    0
  } else {
    1 + ((dcode - ndirect - 16) >> (npostfix + 1))
  }
}

///|
fn distance_of(
  code : Int32,
  extra : Int32,
  npostfix : Int32,
  ndirect : Int32,
  last : Array[Int32],
) -> Int32? {
  @rules.distance(
    code,
    extra,
    npostfix~,
    ndirect~,
    last1=last[0],
    last2=last[1],
    last3=last[2],
    last4=last[3],
  )
}

///|
test "the distance alphabet follows the meta-block header" {
  for npostfix in 0..<=3 {
    for field in 0..<16 {
      let ndirect = @rules.direct_distance_codes(npostfix, field)
      assert_eq(ndirect, field * (1 << npostfix))
      assert_eq(
        @rules.distance_alphabet_size(npostfix, ndirect),
        16 + ndirect + 48 * (1 << npostfix),
      )
    }
  }
  // The largest alphabet, and the most extra bits a code has.
  inspect(@rules.distance_alphabet_size(3, 120), content="520")
  inspect(@rules.distance_extra_bits(519, 3, 120), content="24")
}

///|
test "short codes agree with RFC 7932 for every ring of small distances" {
  let values = [1, 2, 3, 4, 5, 6]
  let rings = []
  for a in values {
    for b in values {
      for c in values {
        for d in values {
          rings.push([a, b, c, d])
        }
      }
    }
  }
  rings.push([16, 15, 11, 4])
  rings.push([0x3ff_fff0, 0x3ff_ffff, 7, 1])
  for last in rings {
    for code in 0..<16 {
      for npostfix in 0..<=3 {
        let ndirect = npostfix * 4
        assert_eq(@rules.distance_extra_bits(code, npostfix, ndirect), 0)
        assert_eq(
          distance_of(code, 0, npostfix, ndirect, last),
          reference_distance(code, 0, npostfix, ndirect, last),
        )
      }
    }
  }
  // Below one: the last distance minus three when it is 3.
  debug_inspect(distance_of(8, 0, 0, 0, [3, 1, 1, 1]), content="None")
}

///|
test "direct codes and codes with extra bits agree with RFC 7932" {
  let last = [16, 15, 11, 4]
  for npostfix in 0..<=3 {
    for field in 0..<16 {
      let ndirect = field << npostfix
      let size = @rules.distance_alphabet_size(npostfix, ndirect)
      for code in 16..<size {
        let bits = @rules.distance_extra_bits(code, npostfix, ndirect)
        assert_eq(bits, ref_extra_bits(code, npostfix, ndirect))
        assert_true(bits <= 24)
        let top = (1 << bits) - 1
        for extra in [0, 1, top / 2, top] {
          let extra = extra.min(top)
          assert_eq(
            distance_of(code, extra, npostfix, ndirect, last),
            reference_distance(code, extra, npostfix, ndirect, last),
          )
        }
      }
    }
  }
}

///|
test "codes with extra bits cover the distances past the direct ones without gaps" {
  // Each code with extra bits names a block of distances; together, the
  // blocks of the codes with at most 8 extra bits tile an interval.
  for npostfix in 0..<=3 {
    for field in [0, 1, 15] {
      let ndirect = field << npostfix
      let seen : Map[Int32, Unit] = Map([])
      let mut count = 0
      for code = 16 + ndirect; ; code = code + 1 {
        let bits = @rules.distance_extra_bits(code, npostfix, ndirect)
        if bits > 8 {
          break
        }
        for extra in 0..<(1 << bits) {
          let d = distance_of(code, extra, npostfix, ndirect, [1, 1, 1, 1])
          guard d is Some(d) else { fail("no distance") }
          assert_false(seen.contains(d))
          seen[d] = ()
          count += 1
        }
      }
      for d in (ndirect + 1)..<(ndirect + 1 + count) {
        assert_true(seen.contains(d))
      }
    }
  }
}
