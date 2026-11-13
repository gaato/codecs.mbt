///|
test "sequence sections: every mode, large counts, long extras and near-window offsets" {
  let seen = FixedArray::make(4, false)
  let selected = []
  for c in @seqcases.cases() {
    assert_true(decompress(c.frame) == c.input, msg=c.name)
    for modes in c.modes {
      seen[modes.0] = true
      seen[modes.1] = true
      seen[modes.2] = true
    }
    selected.push("\{c.name}: \{Repr(c.modes)}")
  }
  assert_true(seen.iter().all(x => x))
  inspect(
    selected.join("\n"),
    content=(
      #|predefined: [(0, 0, 0)]
      #|fse: [(2, 2, 2)]
      #|repeat-fse: [(2, 2, 2), (3, 3, 3), (3, 3, 3)]
      #|repeat-rle: [(2, 1, 1), (1, 3, 3), (3, 3, 3)]
      #|many-sequences: [(2, 2, 1)]
      #|long-extras: [(1, 1, 1)]
      #|window-offset: [(1, 1, 1)]
      #|repeat-edges: [(0, 2, 2)]
      #|treeless-across-raw-rle: []
    ),
  )
}

///|
test "treeless literals retain the table across raw and RLE blocks, and reset drops it" {
  let rng = Rng::new(223)
  let writer = LiteralsWriter::new()
  let data = FixedArray::makei(2000, _ => rng.below(32).to_byte())
  let first = writer.plan(data, 0, data.length())
  assert_true(first.kind is LitHuffman(_))
  let out = @bits.BitPacker()
  write_frame_header(out, None, 17, false, false)
  write_block_header(out, false, COMPRESSED_BLOCK, first.size + 1)
  writer.write(out, first, data, 0, data.length())
  out.write(8, 0)
  write_block_header(out, false, RAW_BLOCK, 1)
  out.write(8, 42)
  write_block_header(out, false, RLE_BLOCK, 100)
  out.write(8, 42)
  let again = writer.plan(data, 0, data.length())
  assert_true(again.kind is LitTreeless(_))
  write_block_header(out, true, COMPRESSED_BLOCK, again.size + 1)
  writer.write(out, again, data, 0, data.length())
  out.write(8, 0)
  let expected = Bytes::from_array(data[:]) +
    Bytes::make(101, b'\x2a') +
    Bytes::from_array(data[:])
  assert_true(decompress(Bytes::from_array(written(out))) == expected)
  writer.reset()
  assert_true(writer.plan(data, 0, data.length()).kind is LitHuffman(_))
}

///|
test "31-bit offset extras survive every partial byte alignment" {
  for prefix in 0..<8 {
    for value in [0, 1, 0xffff, 0x40000000, 0x7fffffff] {
      let out = @bits.BitPacker()
      out.write(prefix, 0)
      out.write(31, value)
      out.write_end_mark()
      let data = FixedArray::from_array(written(out))
      let bits = BackwardBits::new(data, 0, data.length()) catch {
        _ => fail("no end mark")
      }
      // read_long supports this split without relying on 1 << 31.
      assert_eq((bits.read(15) << 16) | bits.read(16), value)
      assert_eq(bits.read(prefix), 0)
      assert_eq(bits.pos, 0)
    }
  }
}

///|
test "fast and double-fast levels see the same blocks with one-byte input steps" {
  let input = sample_text(Rng::new(812), 280000)
  for level in [1, 2, 3, 4, 12] {
    let whole = compress(input, level~)
    let split = encode_drive(
      Encoder(level~, content_size=input.length().to_int64()),
      input,
      next_in=() => 1,
      next_out=() => 997,
    )
    assert_true(whole == split)
    assert_true(decompress(split) == input)
  }
}
