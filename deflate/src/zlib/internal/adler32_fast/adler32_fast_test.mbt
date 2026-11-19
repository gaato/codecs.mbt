///|
/// Deterministic bytes (xorshift32), so that a failure reproduces.
fn random_bytes(n : Int32, seed : UInt32) -> FixedArray[Byte] {
  let mut s = seed
  FixedArray::makei(n, _ => {
    s = s ^ (s << 13)
    s = s ^ (s >> 17)
    s = s ^ (s << 5)
    (s >> 24).to_byte()
  })
}

///|
/// `update` over `data[off:off + len]` against `@adler32.update`, from two
/// starting values, the second with both sums near the modulus.
fn check(data : FixedArray[Byte], off : Int32, len : Int32) -> Unit raise {
  for adler in [@adler32.INITIAL, 0xFFF0FFF0U] {
    let view = data[off:off + len]
    let want = @adler32.update(adler, view)
    let got = @adler32_fast.update(adler, view)
    if got != want {
      fail("off=\{off} len=\{len} adler=\{adler}: got \{got}, want \{want}")
    }
  }
}

///|
test "known value" {
  let data : FixedArray[Byte] = FixedArray::makei(9, i => b"Wikipedia"[i])
  assert_eq(@adler32_fast.update(@adler32.INITIAL, data[:]), 0x11E60398U)
}

///|
test "equal to @adler32.update around groups and reductions, at every alignment" {
  let lens = [
    0, 1, 15, 16, 17, 31, 32, 33, 5536, 5551, 5552, 5553, 5568, 11103, 11104, 11105,
    70000,
  ]
  let random = random_bytes(70016, 0x9E3779B9)
  // All 0xff bytes: the largest sums, where an overflow would show.
  let ones = FixedArray::make(70016, b'\xFF')
  for len in lens {
    for off in 0..<16 {
      check(random, off, len)
      check(ones, off, len)
    }
  }
}

///|
test "equal to @adler32.update, random lengths and alignments" {
  let data = random_bytes(70016, 12345)
  let mut s = 2463534242U
  for _ in 0..<200 {
    s = s ^ (s << 13)
    s = s ^ (s >> 17)
    s = s ^ (s << 5)
    let len = (s % 70001).reinterpret_as_int()
    let off = ((s >> 20) % 16).reinterpret_as_int()
    check(data, off, len)
  }
}

///|
test "in pieces, the same as whole" {
  let data = random_bytes(20000, 7)
  let whole = @adler32_fast.update(@adler32.INITIAL, data[:])
  for piece in [1, 15, 16, 17, 5552, 7000] {
    let mut adler = @adler32.INITIAL
    let mut i = 0
    while i < data.length() {
      let end = (i + piece).min(data.length())
      adler = @adler32_fast.update(adler, data[i:end])
      i = end
    }
    assert_eq(adler, whole, msg="piece \{piece}")
  }
}

///|
test "short and SIMD updates agree with the reference across random splits" {
  // An empty update preserves both halves, even when they are unreduced.
  // With the same starting value, a zero byte takes b past 2 * BASE.
  let edge = FixedArray::make(1, b'\x00')
  for n in 0..<=1 {
    assert_eq(
      @adler32_fast.update(0xFFFFFFF0U, edge[:n]),
      @adler32.update(0xFFFFFFF0U, edge[:n]),
    )
  }
  @quickcheck.check(
    (c : (UInt32, UInt32, UInt16, UInt16)) => {
      let data = random_bytes(64, c.0)
      for n in 0..<=64 {
        let first = c.2.to_int() % (n + 1)
        let second = first + c.3.to_int() % (n - first + 1)
        let want = @adler32.update(c.1, data[:n])
        let a = @adler32_fast.update(c.1, data[:first])
        let b = @adler32_fast.update(a, data[first:second])
        if @adler32_fast.update(b, data[second:n]) != want ||
          @adler32_fast.update(c.1, data[:n]) != want {
          return false
        }
      }
      true
    },
    count=300,
    seed=2026,
  )
}
