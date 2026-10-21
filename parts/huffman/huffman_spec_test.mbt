// Specifications of the in-place builders, as properties and reference
// implementations written for clarity rather than speed.

///|
/// A deterministic pseudo-random sequence (a linear congruential
/// generator).
struct Rng {
  mut state : Int32
}

///|
fn Rng::next(self : Rng, bound : Int32) -> Int32 {
  self.state = (self.state * 1103515245 + 12345) & 0x7fff_ffff
  (self.state >> 8) % bound
}

///|
/// Frequencies for `n` symbols, about a third of them zero, skewed so that
/// some codes come out long.
fn random_freqs(rng : Rng, n : Int32) -> FixedArray[Int32] {
  FixedArray::makei(n, _ => {
    match rng.next(3) {
      0 => 0
      1 => 1 + rng.next(4)
      _ => 1 << rng.next(16)
    }
  })
}

///|
/// The cost, the sum of frequency times length, of an optimal prefix code
/// for `freqs`: Huffman's algorithm, joining the two lightest weights until
/// one is left, adds each join's weight once per level below it.
fn optimal_cost(freqs : FixedArray[Int32]) -> Int64 {
  let weights = []
  for f in freqs {
    if f > 0 {
      weights.push(f.to_int64())
    }
  }
  if weights.length() == 1 {
    return weights[0]
  }
  let mut cost = 0L
  while weights.length() > 1 {
    weights.sort()
    let joined = weights[0] + weights[1]
    weights.remove(0) |> ignore
    weights[0] = joined
    cost += joined
  }
  cost
}

///|
fn cost(freqs : FixedArray[Int32], lengths : FixedArray[Int32]) -> Int64 {
  for s = 0, sum = 0L; s < freqs.length(); {
    continue s + 1, sum + freqs[s].to_int64() * lengths[s].to_int64()
  } nobreak {
    sum
  }
}

///|
/// The Kraft sum of `lengths`, exactly, in units of `2^-30`.
fn kraft_sum(lengths : FixedArray[Int32]) -> Int64 {
  for s = 0, sum = 0L; s < lengths.length(); {
    let len = lengths[s]
    continue s + 1, if len == 0 { sum } else { sum + (1L << (30 - len)) }
  } nobreak {
    sum
  }
}

///|
test "code lengths: within the limit, complete, and optimal when nothing is cut" {
  let rng = Rng::{ state: 2026, }
  for round in 0..<3000 {
    let n = 1 + rng.next(40)
    let freqs = random_freqs(rng, n)
    let used = freqs.iter().filter(f => f > 0).count()
    // Limits from tight to loose, but never fewer codes than symbols.
    let mut max_bits = 1 + rng.next(15)
    while 1 << max_bits < used {
      max_bits += 1
    }
    let lengths = FixedArray::make(n, -1)
    @huffman.code_lengths(freqs, n, max_bits, lengths)
    for s in 0..<n {
      if freqs[s] == 0 {
        assert_eq(lengths[s], 0)
      } else {
        assert_true(lengths[s] >= 1 && lengths[s] <= max_bits)
      }
    }
    if used >= 2 {
      assert_eq(kraft_sum(lengths), 1L << 30)
    }
    // With at most 16 used symbols no code is longer than 15 bits, so
    // nothing is cut and the code is an optimal one.
    if used <= 16 && round % 2 == 0 {
      @huffman.code_lengths(freqs, n, 15, lengths)
      assert_eq(cost(freqs, lengths), optimal_cost(freqs))
    }
  }
}

///|
/// The low `n` bits of `code`, reversed, one at a time.
fn reference_reverse(code : Int32, n : Int32) -> Int32 {
  let bits = Array::makei(n, i => (code >> i) & 1)
  for i, b in bits.rev(); r = 0 {
    continue r | (b << i)
  } nobreak {
    r
  }
}

///|
test "reverse_bits reverses, and is an involution" {
  for n in 0..<=15 {
    for code in 0..<(1 << n) {
      let r = @huffman.reverse_bits(code, n)
      assert_eq(r, reference_reverse(code, n))
      assert_eq(@huffman.reverse_bits(r, n), code)
    }
  }
}

///|
/// Canonical codes as RFC 1951 section 3.2.2 defines them, most significant
/// bit first: in order of (length, symbol), each code is the one before it
/// plus one, shifted left to its length.
fn reference_canonical(lengths : FixedArray[Int32]) -> FixedArray[Int32] {
  let order = Array::makei(lengths.length(), s => s).filter(s => lengths[s] > 0)
  order.sort_by((a, b) => {
    if lengths[a] != lengths[b] {
      lengths[a].compare(lengths[b])
    } else {
      a.compare(b)
    }
  })
  let codes = FixedArray::make(lengths.length(), 0)
  for i = 0, code = 0, len = 0; i < order.length(); {
    let s = order[i]
    let code = code << (lengths[s] - len)
    codes[s] = code
    continue i + 1, code + 1, lengths[s]
  }
  codes
}

///|
test "canonical codes: increasing in (length, symbol) order and prefix-free" {
  let rng = Rng::{ state: 7, }
  for _ in 0..<2000 {
    let n = 1 + rng.next(40)
    let freqs = random_freqs(rng, n)
    let lengths = FixedArray::make(n, 0)
    // Limits of 6 bits and up leave room for all 40 symbols.
    @huffman.code_lengths(freqs, n, 6 + rng.next(10), lengths)
    let codes = FixedArray::make(n, -1)
    @huffman.canonical_codes(lengths, n, codes)
    let msb_first = FixedArray::makei(n, s => {
      @huffman.reverse_bits(codes[s], lengths[s])
    })
    let expected = reference_canonical(lengths)
    for s in 0..<n {
      assert_eq(msb_first[s], expected[s])
      if lengths[s] == 0 {
        assert_eq(codes[s], 0)
      }
    }
    // Left-aligned to 16 bits, codes grow with (length, symbol), and no code
    // is a prefix of another: each starts past the end of the one before.
    let order = Array::makei(n, s => s).filter(s => lengths[s] > 0)
    order.sort_by((a, b) => {
      if lengths[a] != lengths[b] {
        lengths[a].compare(lengths[b])
      } else {
        a.compare(b)
      }
    })
    for i in 1..<order.length() {
      let a = order[i - 1]
      let b = order[i]
      let end_a = (msb_first[a] + 1) << (16 - lengths[a])
      let start_b = msb_first[b] << (16 - lengths[b])
      assert_true(start_b >= end_a)
    }
  }
}
