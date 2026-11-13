// The encoder's Huffman coding (internal/huffenc) against the decoder's:
// tree descriptions read back by `Huffman::read`, and literal streams,
// one and four, decoded by `Huffman::decode` to the literals encoded.

///|
/// Builds a code for `literals`, writes its description and the literals
/// in one stream and in four (when there are 6 or more), and decodes them
/// with the decoder. Returns whether the weights were FSE-compressed, or
/// None when `build` found no code.
fn check_huffman(literals : Array[Int32]) -> Bool? raise {
  let counts = histogram(literals, 256)
  let encoder = @huffenc.HuffmanEncoder()
  guard encoder.build(counts) else { return None }
  let data = FixedArray::makei(literals.length(), i => literals[i].to_byte())
  let n = data.length()
  let compressed = for four in [false, true] {
    if four && n < 6 {
      continue
    }
    let out = @bits.BitPacker()
    encoder.write_description(out)
    let description = encoder.description_size()
    encoder.write_literals(out, data, 0, n, four_streams=four)
    let bytes = packed(out)
    let huffman = Huffman::new()
    let used = huffman.read(bytes, 0, bytes.length(), FseScratch::new())
    assert_eq(used, description)
    assert_eq(huffman.max_bits, encoder.max_bits())
    let decoded = FixedArray::make(n, b'\x00')
    huffman.decode(bytes, used, bytes.length(), decoded, n, four)
    assert_eq(decoded, data)
    // The streams' bits are the cost, plus each stream's end mark and
    // padding.
    let streams = if four { 4 } else { 1 }
    let stream_bytes = bytes.length() - used - (if four { 6 } else { 0 })
    let bits = encoder.cost(counts)
    assert_true(stream_bytes * 8 >= bits + streams)
    assert_true(stream_bytes * 8 <= bits + 8 * streams)
    // Kraft: the code is complete.
    let mut kraft = 0
    for s in 0..<256 {
      if counts[s] > 0 {
        let len = huffman_length(huffman, s)
        assert_true(len >= 1 && len <= 11)
        kraft += 1 << (11 - len)
      }
    }
    assert_eq(kraft, 1 << 11)
  } nobreak {
    bytes_compressed(encoder)
  }
  Some(compressed)
}

///|
/// The code length the decoder's table gives symbol `s`, or 0.
fn huffman_length(huffman : Huffman, s : Int32) -> Int32 {
  for i in 0..<(1 << huffman.max_bits) {
    if huffman.symbol[i].to_int() == s {
      return huffman.nbits[i].to_int()
    }
  }
  0
}

///|
/// Whether the encoder's description holds FSE-compressed weights.
fn bytes_compressed(encoder : @huffenc.HuffmanEncoder) -> Bool {
  let out = @bits.BitPacker()
  encoder.write_description(out)
  packed(out)[0].to_int() < 128
}

///|
test "Huffman encoding: one byte value gives no code" {
  debug_inspect(check_huffman([]), content="None")
  debug_inspect(check_huffman([7]), content="None")
  debug_inspect(check_huffman(Array::make(1000, 255)), content="None")
}

///|
test "Huffman encoding: two byte values" {
  debug_inspect(check_huffman([0, 1]), content="Some(false)")
  debug_inspect(
    check_huffman([200, 3, 3, 3, 3, 3, 200]),
    content=(
      #|Some(true)
    ),
  )
  debug_inspect(
    check_huffman([255, 0, 0, 0, 0, 0, 0, 0, 0]),
    content="Some(true)",
  )
  // Weights that need four streams of their own: 6 literals, the last
  // stream empty.
  debug_inspect(check_huffman([1, 2, 1, 2, 1, 2]), content="Some(false)")
}

///|
test "Huffman encoding: every byte value, compressed weights" {
  // Skewed counts: weights of many values, more than 128 of them.
  let literals = []
  for s in 0..<256 {
    for _ in 0..<(1 + s * s % 61) {
      literals.push(s)
    }
  }
  debug_inspect(check_huffman(literals), content="Some(true)")
  // Every byte value as often: all weights equal, which only the direct
  // form could hold, and it holds 128 at most.
  let flat = [ for i in 0..<1024 => i % 256 ]
  debug_inspect(check_huffman(flat), content="None")
  // The first 129 byte values as often: codes of 7 and 8 bits, past the
  // direct form.
  debug_inspect(
    check_huffman([ for i in 0..<1290 => i % 129 ]),
    content=(
      #|Some(true)
    ),
  )
  // 128 of them fit the direct form.
  debug_inspect(
    check_huffman([ for i in 0..<1280 => i % 128 ]),
    content="Some(false)",
  )
}

///|
test "Huffman encoding: codes limited to 11 bits" {
  // Fibonacci counts would give codes of up to 20 bits.
  let literals = []
  for s = 0, a = 1, b = 1; s < 21; {
    for _ in 0..<a {
      literals.push(s * 12)
    }
    continue s + 1, b, a + b
  }
  check_huffman(literals) |> ignore
}

///|
test "Huffman encoding: random literals round-trip" {
  let rng = Rng::new(4224)
  let compressed = [0, 0]
  for round in 0..<300 {
    let alphabet = 2 + rng.below([4, 30, 256][round % 3] - 1)
    let skew = rng.below(4)
    let n = 2 + rng.below([10, 500, 5000][rng.below(3)])
    let literals = []
    for _ in 0..<n {
      let mut s = rng.below(alphabet)
      for _ in 0..<skew {
        s = s.min(rng.below(alphabet))
      }
      literals.push(s)
    }
    match check_huffman(literals) {
      Some(true) => compressed[1] += 1
      Some(false) => compressed[0] += 1
      None => ()
    }
  }
  // Both forms of the weights came up.
  assert_true(compressed[0] > 20 && compressed[1] > 20)
}
