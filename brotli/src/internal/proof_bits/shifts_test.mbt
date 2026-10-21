// Generated from parts/proof_bits/shifts_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// What stands behind the contracts of shifts.mbt, which `moon prove` trusts:
// each bridge agrees with its arithmetic for every shift its precondition
// allows, on every `x` below 2^16, on both sides of every power of two, and
// at the largest `x` the precondition allows.

///|
/// 2^k by repeated doubling, independent of the bit operations under test.
fn power_of_two(k : Int32) -> Int64 {
  for i = 0, p = 1L; i < k; {
    continue i + 1, p * 2
  } nobreak {
    p
  }
}

///|
/// The `x` the tests try: every value below 2^16, then each power of two
/// from 2^16 up with its neighbours, and the largest `Int`.
fn sample() -> Array[Int32] {
  let xs = Array::makei(65536, i => i)
  for m in 16..<31 {
    let p = power_of_two(m).to_int()
    xs.push(p - 1)
    xs.push(p)
    xs.push(p + 1)
  }
  xs.push(0x7FFF_FFFE)
  xs.push(0x7FFF_FFFF)
  xs
}

///|
test "shr and low_bits are division and remainder by 2^k" {
  let xs = sample()
  for k in 0..<=30 {
    let p = power_of_two(k)
    for x in xs {
      assert_eq(@proof_bits.shr(x, k).to_int64(), x.to_int64() / p)
      assert_eq(@proof_bits.low_bits(x, k).to_int64(), x.to_int64() % p)
    }
  }
}

///|
test "shl is multiplication by 2^k while the product fits" {
  let xs = sample()
  for k in 0..<=30 {
    let p = power_of_two(k)
    let largest = (0x7FFF_FFFFL / p).to_int()
    for x in [..xs, largest - 1, largest] {
      if x >= 0 && x <= largest {
        assert_eq(@proof_bits.shl(x, k).to_int64(), x.to_int64() * p)
      }
    }
  }
}
