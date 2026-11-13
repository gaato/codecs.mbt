// The encoder's header writers against the decoder's parsers, and every
// kind of literals section through the decoder, including those the
// encoder does not choose yet (raw and RLE literals only pay off once a
// block has sequences).

///|
/// Everything `out` holds, as bytes.
fn written(out : @bits.BitPacker) -> Array[Byte] {
  let data = FixedArray::make(out.pending(), b'\x00')
  out.drain_into(data, 0) |> ignore
  Array::makei(data.length(), i => data[i])
}

///|
test "literals headers parse back to what was written, at every size class" {
  let sizes = [
    0, 1, 5, 6, 31, 32, 255, 256, 1023, 1024, 4095, 4096, 16383, 16384, 65535, 131072,
    262143,
  ]
  let lengths = []
  for kind in [0, 1] {
    for n in sizes {
      let out = @bits.BitPacker()
      write_raw_literals_header(out, kind, n)
      let header = written(out)
      assert_eq(header.length(), raw_literals_header_len(n))
      // The section after it: the literals, or the one byte.
      let payload = if kind == 0 { n } else { 1 }
      let section = [..header, ..Array::make(payload, b'\x00')]
      let parsed = @header.parse_literals_header(section[:], 1 << 20).unwrap()
      assert_eq(parsed.regenerated, n)
      assert_eq(parsed.compressed, payload)
      assert_eq(parsed.header_len, header.length())
      assert_eq(
        parsed.block_type,
        if kind == 0 {
          @header.RawLiterals
        } else {
          @header.RleLiterals
        },
      )
      if kind == 0 {
        lengths.push(header.length())
      }
    }
  }
  inspect(
    lengths.map(n => n.to_string()).join(" "),
    content="1 1 1 1 1 2 2 2 2 2 2 3 3 3 3 3 3",
  )
  let compressed_lengths = []
  for four in [false, true] {
    for n in sizes {
      // A single stream holds fewer than 1024 literals; four, at least 6.
      if (!four && n >= 1024) || (four && n < 6) {
        continue
      }
      for payload in [1, n / 2 + 1, n] {
        let out = @bits.BitPacker()
        write_compressed_literals_header(out, n, payload, four)
        let header = written(out)
        assert_eq(
          header.length(),
          compressed_literals_header_len(n, payload, four),
        )
        let section = [..header, ..Array::make(payload, b'\x00')]
        let parsed = @header.parse_literals_header(section[:], 1 << 20).unwrap()
        let label = "\{n} \{payload} \{four}"
        assert_eq(parsed.block_type, @header.CompressedLiterals, msg=label)
        assert_eq(parsed.regenerated, n, msg=label)
        assert_eq(parsed.compressed, payload, msg=label)
        assert_eq(parsed.four_streams(), four, msg=label)
        assert_eq(parsed.header_len, header.length(), msg=label)
        if payload == n {
          compressed_lengths.push(header.length())
        }
      }
    }
  }
  inspect(
    compressed_lengths.map(n => n.to_string()).join(" "),
    content=(
      #|3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 4 4 4 4 5 5 5 5
    ),
  )
}

///|
test "block headers parse back to what was written" {
  for last in [false, true] {
    for kind in [RAW_BLOCK, RLE_BLOCK, COMPRESSED_BLOCK] {
      for size in [0, 1, 255, 256, 65535, 131071, 131072, (1 << 21) - 1] {
        let out = @bits.BitPacker()
        write_block_header(out, last, kind, size)
        let b = written(out)
        assert_eq(b.length(), 3)
        let value = b[0].to_int() | (b[1].to_int() << 8) | (b[2].to_int() << 16)
        let h = @header.parse_block_header(value).unwrap()
        assert_eq(h.last, last)
        assert_eq(h.size, size)
        let expected : @header.BlockType = match kind {
          RAW_BLOCK => Raw
          RLE_BLOCK => Rle
          _ => Compressed
        }
        assert_eq(h.block_type, expected)
      }
    }
  }
}

///|
test "frame headers parse back, at every content size field" {
  let sizes : Array[Int64?] = [
    None,
    Some(0),
    Some(255),
    Some(256),
    Some(65791),
    Some(65792),
    Some(1L << 20),
    Some(0xFFFFFFFEL),
    Some(0xFFFFFFFFL),
    Some(1L << 40),
  ]
  let lengths = []
  for size in sizes {
    for checksum in [false, true] {
      for window_log in [10, 19, 22] {
        let single = size is Some(s) && s <= 1L << window_log
        let out = @bits.BitPacker()
        write_frame_header(out, size, window_log, single, checksum)
        let bytes = written(out)
        assert_eq(bytes[0:4].to_owned(), [b'\x28', b'\xb5', b'\x2f', b'\xfd'])
        let fh = @header.parse_frame_header(bytes[4:]).unwrap()
        let label = "\{Repr(size)} \{checksum} \{window_log}"
        assert_eq(fh.header_len, bytes.length() - 4, msg=label)
        assert_eq(fh.has_checksum, checksum, msg=label)
        assert_eq(fh.single_segment, single, msg=label)
        assert_eq(fh.dictionary_id, 0, msg=label)
        assert_eq(
          fh.content_size,
          size.map(s => s.reinterpret_as_uint64()),
          msg=label,
        )
        if !single {
          assert_eq(fh.window_size, 1UL << window_log, msg=label)
        }
        if checksum && window_log == 22 {
          lengths.push(bytes.length())
        }
      }
    }
  }
  // Magic and descriptor, the window unless single-segment, then 0, 1, 2,
  // 4 or 8 bytes of content size.
  inspect(
    lengths.map(n => n.to_string()).join(" "),
    content=(
      #|6 6 6 7 7 9 9 10 14 14
    ),
  )
}

///|
fn kind_name(kind : LiteralsKind) -> String {
  match kind {
    LitRaw => "raw"
    LitRle => "rle"
    LitHuffman(four~) => if four { "huffman four" } else { "huffman one" }
    LitTreeless(four~) => if four { "treeless four" } else { "treeless one" }
  }
}

///|
/// A frame of one compressed block, the last, holding the literals section
/// `plan` describes for `literals` and no sequences, under a 128 KiB window:
/// a single-segment frame would limit its blocks to the content size.
fn literals_frame(
  writer : LiteralsWriter,
  plan : LiteralsPlan,
  literals : FixedArray[Byte],
) -> Bytes {
  let out = @bits.BitPacker()
  let n = literals.length()
  write_frame_header(out, None, 17, false, false)
  write_block_header(out, true, COMPRESSED_BLOCK, plan.size + 1)
  writer.write(out, plan, literals, 0, n)
  out.write(8, 0)
  Bytes::from_array(written(out))
}

///|
test "every kind of literals section decodes" {
  let rng = Rng::new(3111)
  let writer = LiteralsWriter::new()
  let kinds = []
  let inputs : Array[FixedArray[Byte]] = [
    FixedArray::make(1, b'q'),
    FixedArray::make(40, b'q'),
    FixedArray::make(5000, b'q'),
    FixedArray::makei(31, i => (i % 3).to_byte()),
    FixedArray::makei(32, i => (i % 3).to_byte()),
    FixedArray::makei(255, i => (i % 5 + i % 2).to_byte()),
    FixedArray::makei(256, i => (i % 5 + i % 2).to_byte()),
    FixedArray::makei(4096, _ => (rng.below(1 << 16) >> 8).to_byte()),
    FixedArray::makei(20000, _ => ((rng.below(1 << 16) >> 8) & 7).to_byte()),
    FixedArray::makei(MAX_BLOCK_SIZE, _ => {
      ((rng.below(1 << 16) >> 8) & 31).to_byte()
    }),
  ]
  for literals in inputs {
    writer.reset()
    let n = literals.length()
    let best = writer.plan(literals, 0, n)
    kinds.push("\{n} \{kind_name(best.kind)}")
    // The plan chosen, and each other kind the literals allow, with the
    // size it would take.
    let plans = [
      { kind: LitRaw, size: raw_literals_header_len(n) + n, payload: n, },
    ]
    if literals.iter().all(b => b == literals[0]) {
      plans.push({
        kind: LitRle,
        size: raw_literals_header_len(n) + 1,
        payload: 1,
      })
    }
    for plan in plans {
      assert_true(plan.size >= best.size)
    }
    plans.push(best)
    for plan in plans {
      // A block holds at most 128 KiB.
      if plan.size + 1 > MAX_BLOCK_SIZE {
        continue
      }
      // `write` takes a Huffman plan only right after `plan` made it.
      if plan.kind is LitHuffman(_) {
        writer.plan(literals, 0, n) |> ignore
      }
      let frame = literals_frame(writer, plan, literals)
      let (blocks, _) = frame_blocks(frame)
      assert_eq(blocks[0].2, plan.size + 1)
      let got = decompress(frame) catch {
        @codec.CodecError(kind, message) =>
          fail("\{n} \{kind_name(plan.kind)}: \{Repr(kind)} \{message}")
      }
      assert_true(
        got == Bytes::from_array(literals[:]),
        msg="\{n} \{kind_name(plan.kind)}",
      )
    }
  }
  inspect(
    kinds.join("\n"),
    content=(
      #|1 raw
      #|40 rle
      #|5000 rle
      #|31 huffman one
      #|32 huffman one
      #|255 huffman one
      #|256 huffman four
      #|4096 raw
      #|20000 huffman four
      #|131072 huffman four
    ),
  )
}
