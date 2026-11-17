///|
priv struct BitWriter {
  out : Buffer
  mut acc : Int32
  mut count : Int32
}

///|
fn BitWriter::new() -> BitWriter {
  { out: Buffer(), acc: 0, count: 0, }
}

///|
fn BitWriter::bits(self : BitWriter, value : Int32, count : Int32) -> Unit {
  for i in 0..<count {
    self.acc = self.acc | (((value >> i) & 1) << self.count)
    self.count += 1
    if self.count == 8 {
      self.out.write_byte(self.acc.to_byte())
      self.acc = 0
      self.count = 0
    }
  }
}

///|
fn BitWriter::align(self : BitWriter) -> Unit {
  if self.count != 0 {
    self.bits(0, 8 - self.count)
  }
}

///|
fn reversed(value : Int32, count : Int32) -> Int32 {
  for i in 0..<count; out = 0 {
    continue (out << 1) | ((value >> i) & 1)
  } nobreak {
    out
  }
}

///|
fn BitWriter::fixed(self : BitWriter, symbol : Int32) -> Unit {
  let (code, count) = if symbol < 144 {
    (0x30 + symbol, 8)
  } else if symbol < 256 {
    (0x190 + symbol - 144, 9)
  } else if symbol < 280 {
    (symbol - 256, 7)
  } else {
    (0xc0 + symbol - 280, 8)
  }
  self.bits(reversed(code, count), count)
}

///|
fn BitWriter::stored(self : BitWriter, prefix : Bytes) -> Unit {
  for pos = 0; pos < prefix.length(); {
    let size = (prefix.length() - pos).min(65535)
    self.bits(0, 3) // Non-final stored block.
    self.align()
    self.bits(size, 16)
    self.bits(size ^ 65535, 16)
    self.out.write_bytesview(prefix[pos:pos + size])
    continue pos + size
  }
}

///|
fn fixed_match(prefix : Bytes, length : Int32, distance : Int32) -> Bytes {
  let w = BitWriter::new()
  w.stored(prefix)
  w.bits(3, 3) // Final fixed block.
  w.fixed(285)
  w.bits(length - 3, 16)
  let slot = if distance <= 32768 {
    0
  } else if distance <= 49152 {
    30
  } else {
    31
  }
  w.bits(reversed(slot, 5), 5)
  if slot >= 30 {
    w.bits(distance - (if slot == 30 { 32769 } else { 49153 }), 14)
  }
  w.fixed(256)
  w.align()
  w.out.to_bytes()
}

///|
fn copied(prefix : Bytes, length : Int32, distance : Int32) -> Bytes {
  let bytes = prefix.to_array()
  for _ in 0..<length {
    bytes.push(bytes[bytes.length() - distance])
  }
  Bytes::from_array(bytes)
}

///|
// 15-bit codes for both the extended length and distance, plus their 16/14
// extra bits: the longest atomic unit, requiring up to seven stashed bytes.
fn long_codes(prefix : Bytes) -> Bytes {
  let lit = FixedArray::make(286, 0)
  let dist = FixedArray::make(32, 0)
  for i in 0..<14 {
    lit[i] = i + 1
    dist[i] = i + 1
  }
  lit[256] = 15
  lit[285] = 15
  dist[30] = 15
  dist[31] = 15
  let lc = FixedArray::make(286, 0)
  let dc = FixedArray::make(32, 0)
  @huffman.canonical_codes(lit, 286, lc)
  @huffman.canonical_codes(dist, 32, dc)
  let w = BitWriter::new()
  w.stored(prefix)
  w.bits(5, 3)
  w.bits(29, 5)
  w.bits(31, 5)
  w.bits(15, 4)
  for
    symbol in [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15] {
    w.bits(if symbol < 16 { 4 } else { 0 }, 3)
  }
  for len in lit {
    w.bits(reversed(len, 4), 4)
  }
  for len in dist {
    w.bits(reversed(len, 4), 4)
  }
  for _ in 0..<3 {
    w.bits(lc[0], lit[0])
  }
  w.bits(lc[285], 15)
  w.bits(65535, 16)
  w.bits(dc[31], 15)
  w.bits(16383, 14)
  w.bits(lc[256], 15)
  w.align()
  w.out.to_bytes()
}

///|
fn check_stream(
  stream : Bytes,
  expected : Bytes,
  require_stash~ : Bool = false,
) -> Unit raise {
  assert_eq(decompress(stream), expected)
  let mut most_kept = 0
  for (chunk, room) in [(1 << 20, 1 << 17), (1, 7), (73, 1), (19, 977)] {
    let rng = @fixtures.Rng::new(1951)
    let d = Decoder()
    let (got, consumed) = @fixtures.drive(
      d,
      stream,
      next_in=() => if chunk == 19 { 1 + rng.below(19) } else { chunk },
      next_out=() => room,
      step_into=(d, input, output, end) => d.step_into(input, output, end~),
      check=(d, _) => {
        most_kept = most_kept.max(d.inflater.kept_bytes())
        assert_true(d.inflater.kept_bytes() <= 7)
        assert_eq(d.memory_usage(), decoder_memory_bound().to_int())
      },
    )
    assert_true(got == expected)
    assert_eq(consumed, stream.length())
  }
  if require_stash {
    assert_eq(most_kept, 7)
  }
}

///|
test "Deflate64 length 285 uses all sixteen extra bits and can exceed the window" {
  for length in [3, 258, 65535, 65536, 65537, 65538] {
    check_stream(fixed_match(b"a", length, 1), Bytes::make(length + 1, b'a'))
  }
}

///|
test "Deflate64 distances span both extra codes and the exact 64 KiB edge" {
  let prefix = Bytes::makei(65536, i => ((i * 13 + (i >> 8)) & 255).to_byte())
  for distance in [32769, 49152, 49153, 65535, 65536] {
    check_stream(
      fixed_match(prefix, 300, distance),
      copied(prefix, 300, distance),
    )
  }
  let short = prefix[:65535].to_owned()
  check_stream(fixed_match(short, 3, 65535), copied(short, 3, 65535))
  try decompress(fixed_match(short, 3, 65536)) catch {
    @codec.CodecError(Corrupt, _) => ()
    err => fail("unexpected error: \{Repr(err)}")
  } noraise {
    _ => fail("a distance before the start must fail")
  }
}

///|
test "Deflate64 dynamic distance 31 and maximal match preserve seven input bytes" {
  let prefix = Bytes::makei(65536, i => (i >> 8).to_byte())
  let start = prefix + b"\x00\x00\x00"
  check_stream(
    long_codes(prefix),
    copied(start, 65538, 65536),
    require_stash=true,
  )
}

///|
test "plain DEFLATE retains length 258 and rejects distance codes 30 and 31" {
  let w = BitWriter::new()
  w.bits(3, 3)
  w.fixed(97)
  w.fixed(285) // DEFLATE: length 258, with no extra bits.
  w.bits(0, 5)
  w.fixed(256)
  w.align()
  let stream = w.out.to_bytes()
  assert_eq(@deflate.decompress(stream), Bytes::make(259, b'a'))
  try decompress(stream) catch {
    @codec.CodecError(Truncated, _) => ()
    err => fail("unexpected error: \{Repr(err)}")
  } noraise {
    _ => fail("Deflate64 must read the extra bits")
  }
  for distance in [32769, 65536] {
    let prefix = Bytes::make(65536, b'a')
    let stream = fixed_match(prefix, 3, distance)
    assert_eq(decompress(stream), Bytes::make(65539, b'a'))
    // Use length symbol 257 instead, so the ordinary decoder reaches the
    // exact distance symbol before refusing it (285 has different framing).
    let w = BitWriter::new()
    w.stored(prefix)
    w.bits(3, 3)
    w.fixed(257)
    w.bits(reversed(if distance == 32769 { 30 } else { 31 }, 5), 5)
    w.bits(0, 14)
    w.fixed(256)
    w.align()
    try @deflate.decompress(w.out.to_bytes()) catch {
      @codec.CodecError(Corrupt, message) =>
        assert_eq(message, "an invalid distance code")
      err => fail("unexpected error: \{Repr(err)}")
    } noraise {
      _ => fail("reserved distance accepted")
    }
  }
}
