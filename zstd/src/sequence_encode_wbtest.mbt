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
      #|repeat-history-across-raw-rle-zero: [(1, 1, 1), (1, 1, 3)]
      #|treeless-across-raw-rle: []
    ),
  )
}

///|
test "sequence repeats and tables persist across raw RLE and zero-sequence blocks" {
  for c in @seqcases.cases() {
    if c.name != "repeat-fse" &&
      c.name != "repeat-rle" &&
      c.name != "repeat-history-across-raw-rle-zero" {
      continue
    }
    let decoder = Decoder()
    let out = FixedArray::make(131072, b'\x00')
    let mut pos = 4 + frame_header_of(c.frame).header_len
    let mut begin = 0
    let types = []
    let counts = []
    let modes = []
    let mut index = 0
    for ;; {
      let value = c.frame[pos].to_int() |
        (c.frame[pos + 1].to_int() << 8) |
        (c.frame[pos + 2].to_int() << 16)
      let h = @header.parse_block_header(value).unwrap()
      types.push(h.block_type)
      let end = pos + 3 + (if h.block_type is Rle { 1 } else { h.size })
      if h.block_type is Compressed {
        let bytes = FixedArray::makei(h.size, i => c.frame[pos + 3 + i])
        let lh = @header.parse_literals_header(bytes[:], 131072).unwrap()
        let at = pos + 3 + lh.header_len + lh.compressed
        let first = c.frame[at].to_int()
        let count = if first < 128 {
          first
        } else {
          ((first - 128) << 8) + c.frame[at + 1].to_int()
        }
        counts.push(count)
        if count > 0 {
          let mode = c.frame[at + (if first < 128 { 1 } else { 2 })].to_int()
          modes.push(((mode >> 6) & 3, (mode >> 4) & 3, (mode >> 2) & 3))
          if h.last && c.name == "repeat-history-across-raw-rle-zero" {
            // LL and OF are RLE, ML is Repeat. OF symbol 1 restricts the
            // value to 2..3; the decoded distance 9 below proves value 3.
            assert_eq(c.frame[at + 3].to_int(), 1)
          }
        }
      }
      let status = decoder.step_into(c.frame[begin:end], out, end=h.last)
      if h.last {
        assert_true(status is Done)
      } else {
        assert_true(status is NeedMoreInput)
      }
      if c.name == "repeat-history-across-raw-rle-zero" {
        let expected = if index < 4 { [10U, 1, 4] } else { [9U, 10, 1] }
        for i in 0..<3 {
          assert_true(decoder.rep.get(i) == @seqenc.Distance(expected[i]))
        }
      }
      begin = end
      pos = end
      index += 1
      if h.last {
        break
      }
    }
    // These are parsed from the actual bytes, not fixture metadata.
    assert_eq(modes, c.modes)
    if c.name == "repeat-history-across-raw-rle-zero" {
      assert_eq(types, [Compressed, Raw, Rle, Compressed, Compressed])
      assert_eq(counts, [1, 0, 1])
      let reset = @seqenc.Repeats()
      assert_true(
        reset.resolve(@seqenc.OffsetValue(3), 0) == @seqenc.Distance(0),
      )
      reset.reset()
      let block = @seqenc.Block()
      block.reset(reset, 128)
      block.add(64, 64, @seqenc.Distance(10))
      for i, distance in [10U, 1, 4] {
        assert_true(block.repeats.get(i) == @seqenc.Distance(distance))
      }
      block.add(0, 64, @seqenc.Distance(9))
      let @seqenc.OffsetValue(value) = block.offsets[1]
      assert_eq(value, 3U)
    } else {
      assert_eq(types, [
        Compressed,
        Raw,
        Rle,
        Compressed,
        Compressed,
        Raw,
        Rle,
        Compressed,
        Compressed,
      ])
      assert_eq(
        counts,
        if c.name == "repeat-fse" {
          [2000, 0, 2000, 0, 2000]
        } else {
          [200, 0, 200, 0, 200]
        },
      )
      assert_eq(modes[2], (3, 3, 3))
      assert_eq(modes[1].1, 3)
      assert_eq(modes[1].2, 3)
    }
  }
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
