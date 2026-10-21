// Dynamic blocks written here bit by bit, with codes chosen to reach what
// encoders rarely write: distance codes of 15 bits with 13 extra bits, and
// matches that begin in a preset dictionary and run on into the output. Each
// stream is decoded whole, through the fast path, and a byte at a time,
// through the units alone, and both must give what the tokens say.

///|
priv enum Token {
  Literal(Int32)
  Match(Int32, Int32)
}

///|
priv struct Writer {
  out : Buffer
  mut acc : Int32
  mut nbits : Int32
}

///|
fn Writer::new() -> Writer {
  { out: Buffer(), acc: 0, nbits: 0, }
}

///|
fn Writer::bits(self : Writer, value : Int32, n : Int32) -> Unit {
  for i in 0..<n {
    self.acc = self.acc | (((value >> i) & 1) << self.nbits)
    self.nbits += 1
    if self.nbits == 8 {
      self.out.write_byte(self.acc.to_byte())
      self.acc = 0
      self.nbits = 0
    }
  }
}

///|
fn Writer::finish(self : Writer) -> Bytes {
  if self.nbits > 0 {
    self.out.write_byte(self.acc.to_byte())
  }
  self.out.to_bytes()
}

///|
/// The symbol whose base is the largest at most `value`, and its base.
fn base_symbol(bases : FixedArray[Int32], value : Int32) -> Int32 {
  for i = bases.length() - 1; i >= 0; i = i - 1 {
    if bases[i] <= value {
      return i
    }
  }
  abort("no base")
}

///|
/// A final dynamic block of `tokens`, its codes built from `lit_freqs` and
/// `dist_freqs`, every code length written with a 4-bit code.
fn dynamic_block(
  tokens : Array[Token],
  lit_freqs : FixedArray[Int32],
  dist_freqs : FixedArray[Int32],
) -> Bytes {
  let lit_lengths = FixedArray::make(286, 0)
  let dist_lengths = FixedArray::make(30, 0)
  @huffman.code_lengths(lit_freqs, 286, 15, lit_lengths)
  @huffman.code_lengths(dist_freqs, 30, 15, dist_lengths)
  let lit_codes = FixedArray::make(286, 0)
  let dist_codes = FixedArray::make(30, 0)
  @huffman.canonical_codes(lit_lengths, 286, lit_codes)
  @huffman.canonical_codes(dist_lengths, 30, dist_codes)
  let w = Writer::new()
  w.bits(1, 1)
  w.bits(2, 2)
  w.bits(286 - 257, 5)
  w.bits(30 - 1, 5)
  w.bits(19 - 4, 4)
  // The code-length code: symbols 0 to 15 in 4 bits each, no repeats.
  for s in code_length_order {
    w.bits(if s < 16 { 4 } else { 0 }, 3)
  }
  let cl_lengths = FixedArray::makei(19, s => if s < 16 { 4 } else { 0 })
  let cl_codes = FixedArray::make(19, 0)
  @huffman.canonical_codes(cl_lengths, 19, cl_codes)
  for l in lit_lengths {
    w.bits(cl_codes[l], 4)
  }
  for l in dist_lengths {
    w.bits(cl_codes[l], 4)
  }
  for t in tokens {
    match t {
      Literal(b) => w.bits(lit_codes[b], lit_lengths[b])
      Match(length, distance) => {
        let ls = base_symbol(length_base, length)
        w.bits(lit_codes[257 + ls], lit_lengths[257 + ls])
        w.bits(length - length_base[ls], length_extra[ls])
        let ds = base_symbol(distance_base, distance)
        w.bits(dist_codes[ds], dist_lengths[ds])
        let extra = if ds < 4 { 0 } else { (ds >> 1) - 1 }
        w.bits(distance - distance_base[ds], extra)
      }
    }
  }
  w.bits(lit_codes[256], lit_lengths[256])
  w.finish()
}

///|
/// What `tokens` decode to after `dictionary`.
fn expected(tokens : Array[Token], dictionary : Bytes) -> Bytes {
  let out = dictionary.to_array()
  for t in tokens {
    match t {
      Literal(b) => out.push(b.to_byte())
      Match(length, distance) =>
        for _ in 0..<length {
          out.push(out[out.length() - distance])
        }
    }
  }
  Bytes::from_array(out[dictionary.length():])
}

///|
/// Decodes `stream` with `inflater`, `chunk` input bytes at a time.
fn decode(inflater : Inflater, stream : Bytes, chunk : Int32) -> Bytes raise {
  let out = FixedArray::make(1 << 16, b'\x00')
  let got = Buffer()
  let mut pos = 0
  let mut rest = stream[0:0]
  for ;; {
    if rest.length() == 0 {
      let next = (pos + chunk).min(stream.length())
      rest = stream[pos:next]
      pos = next
    }
    let status = inflater.step_into(rest, out, end=pos == stream.length())
    rest = rest[inflater.last_consumed():]
    got.write_bytes(Bytes::from_array(out[:inflater.last_produced()]))
    if status is Done {
      assert_eq(rest.length(), 0)
      assert_eq(pos, stream.length())
      return got.to_bytes()
    }
  }
}

///|
/// A seeded pseudo-random generator (a 32-bit LCG).
priv struct Rng {
  mut state : UInt32
}

///|
fn Rng::below(self : Rng, bound : Int32) -> Int32 {
  self.state = self.state * 1664525 + 1013904223
  (self.state >> 8).reinterpret_as_int() % bound
}

///|
/// Frequencies that give the last symbols the longest codes.
fn skewed(n : Int32) -> FixedArray[Int32] {
  FixedArray::makei(n, s => if s < 20 { 1 << (20 - s) } else { 1 })
}

///|
test "distance codes of 15 bits with 13 extra bits, through the fast path" {
  let rng = { state: 1951, }
  let tokens = []
  for _ in 0..<33000 {
    tokens.push(Literal(rng.below(256)))
  }
  for _ in 0..<3000 {
    for _ in 0..<rng.below(3) {
      tokens.push(Literal(rng.below(256)))
    }
    tokens.push(Match(3 + rng.below(256), 24577 + rng.below(8192)))
  }
  let lit_freqs = FixedArray::make(286, 1)
  let dist_freqs = skewed(30)
  let stream = dynamic_block(tokens, lit_freqs, dist_freqs)
  let want = expected(tokens, b"")
  let inflater = Inflater::new()
  assert_eq(decode(inflater, stream, stream.length()), want)
  inflater.reset()
  assert_eq(decode(inflater, stream, 1), want)
}

///|
test "matches from a dictionary into the output, through the fast path" {
  let rng = { state: 1950, }
  let dictionary = Bytes::makei(300, i => (i * 7).to_byte())
  let tokens = []
  let mut produced = 0
  // Within the window: 32 KiB of dictionary and output.
  while produced < 32000 - 300 - 260 {
    tokens.push(Literal(rng.below(256)))
    produced += 1
    let length = 3 + rng.below(256)
    tokens.push(Match(length, produced + 1 + rng.below(300)))
    produced += length
  }
  let stream = dynamic_block(tokens, FixedArray::make(286, 1), skewed(30))
  let want = expected(tokens, dictionary)
  let inflater = Inflater::new()
  inflater.reset(dictionary~)
  assert_eq(decode(inflater, stream, stream.length()), want)
  inflater.reset(dictionary~)
  assert_eq(decode(inflater, stream, 1), want)
  // Half the dictionary: a match reaches before it.
  inflater.reset(dictionary=dictionary[150:])
  let failed = try decode(inflater, stream, stream.length()) catch {
    @codec.CodecError(kind, message) => "\{Repr(kind)}: \{message}"
    _ => "other"
  } noraise {
    _ => "decoded"
  }
  inspect(
    failed,
    content="Corrupt: a distance reaches before the start of the data",
  )
}

///|
test "memory: the window, the tables and what builds them" {
  let inflater = Inflater::new()
  debug_inspect(
    (
      inflater.ring.length(),
      inflater.own_lit.length(),
      inflater.own_dist.length(),
      inflater.raw.length(),
      inflater.lit_builder.memory_usage() + inflater.dist_builder.memory_usage(),
      inflater.stash.length(),
    ),
    content="(32768, 1334, 400, 1334, 2808, 8)",
  )
  inspect(inflater.memory_usage(), content="46592")
}
