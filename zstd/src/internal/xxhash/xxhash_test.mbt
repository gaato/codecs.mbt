///|
/// `bytes((i * 31 + 7) & 255 for i in range(n))`.
fn pattern(n : Int32) -> Bytes {
  Bytes::makei(n, i => ((i * 31 + 7) & 255).to_byte())
}

///|
/// `xxhash.xxh64(pattern(n)).intdigest()` from Python's xxhash 4.0.1.
let expected : Array[(Int32, UInt64)] = [
  (0, 17241709254077376921),
  (1, 12208272383309036471),
  (3, 6261856666793576441),
  (4, 14271086647985540868),
  (7, 12663836542954871438),
  (8, 4442176141076628448),
  (31, 5365180931665220769),
  (32, 10184845083914585149),
  (33, 7118499008196474468),
  (63, 6643383451930527103),
  (64, 8915644864283660670),
  (100, 17266991381171192145),
  (1000, 11049950332057828661),
]

///|
test "digests match the reference" {
  for case in expected {
    let (n, digest) = case
    let h = @xxhash.Xxh64()
    h.update_bytes(pattern(n))
    assert_eq(h.digest(), digest)
  }
}

///|
test "any split gives the same digest" {
  let data = pattern(1000)
  let fixed = data.to_fixedarray()
  for step in [1, 3, 8, 31, 32, 33, 500] {
    let h = @xxhash.Xxh64()
    for i = 0; i < 1000; i = i + step {
      h.update(fixed, i, step.min(1000 - i))
    }
    assert_eq(h.digest(), 11049950332057828661)
  }
}

///|
test "exact valid ends and unaligned stripes ignore bytes outside the slice" {
  for n in 1..<=96 {
    let input = pattern(n).to_fixedarray()
    let whole = @xxhash.Xxh64()
    whole.update(input, 0, n)
    for offset in 0..<16 {
      // No trailing allocation padding: the input ends at the array end.
      let unaligned = FixedArray::makei(offset + n, i => {
        if i < offset {
          b'\xff'
        } else {
          input[i - offset]
        }
      })
      for step in [1, 7, 8, 15, 16, 17, 31, 32, 33] {
        let split = @xxhash.Xxh64()
        for i = 0; i < n; i = i + step {
          split.update(unaligned, offset + i, step.min(n - i))
        }
        assert_eq(split.digest(), whole.digest())
      }
    }
  }
}

///|
test "reset starts over and digest leaves the state open" {
  let h = @xxhash.Xxh64()
  h.update_bytes(pattern(63))
  h.reset()
  h.update_bytes(pattern(32))
  assert_eq(h.digest(), 10184845083914585149)
  h.update_bytes(pattern(100)[32:])
  assert_eq(h.digest(), 17266991381171192145)
}
