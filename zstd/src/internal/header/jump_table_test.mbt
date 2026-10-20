///|
/// The stream sizes as RFC 8878 section 3.1.1.3.1.6 gives them: the jump
/// table takes 6 bytes and Stream4_Size is what is left of
/// Total_Streams_Size. The decoder also refuses a total too short for the
/// table and four 1-byte streams, and an empty or negative fourth stream.
fn stream_sizes_ref(
  total : Int32,
  size1 : Int32,
  size2 : Int32,
  size3 : Int32,
) -> Result[(Int32, Int32, Int32, Int32), String] {
  let size4 = total - (6 + size1 + size2 + size3)
  if total < 10 {
    Err("four Huffman streams in fewer than 10 bytes")
  } else if size4 < 1 {
    Err("a Huffman jump table past its streams")
  } else {
    Ok((size1, size2, size3, size4))
  }
}

///|
test "jump tables: a grid of totals and sizes against the RFC" {
  let sizes = [0, 1, 2, 3, 4, 5, 7, 10, 100, 255, 256, 1000, 65535]
  for total in 0..<=300 {
    for size1 in sizes {
      for size2 in sizes {
        for size3 in sizes {
          let actual = @header.stream_sizes(total, size1, size2, size3)
          if actual != stream_sizes_ref(total, size1, size2, size3) {
            fail("total \{total}, sizes \{size1} \{size2} \{size3}")
          }
          if actual is Ok((a, b, c, d)) {
            assert_true(6 + a + b + c + d == total && d > 0)
          }
        }
      }
    }
  }
  // The largest sizes against the largest totals a block allows.
  for total in [(1 << 17) - 1, 1 << 17, 6 + 3 * 65535, 7 + 3 * 65535] {
    for size in [0, 1, 65534, 65535] {
      assert_eq(
        @header.stream_sizes(total, size, size, size),
        stream_sizes_ref(total, size, size, size),
      )
    }
  }
}

///|
test "jump tables: parsed from their bytes" {
  let rng = { state: 11, }
  for _ in 0..<100000 {
    let len = rng.below(40)
    // Small sizes, so that some tables fit their streams.
    let bytes = [
      for i in 0..<len => {
        let high = i < 6 && i % 2 == 1
        (if high { rng.below(8) / 7 } else { rng.below(16) }).to_byte()
      }
    ]
    let byte = i => if i < len { bytes[i].to_int() } else { 0 }
    assert_eq(
      @header.parse_jump_table(bytes[:]),
      stream_sizes_ref(
        len,
        byte(0) + 256 * byte(1),
        byte(2) + 256 * byte(3),
        byte(4) + 256 * byte(5),
      ),
    )
  }
  let table : Array[Byte] = [
    3, 0, 2, 0, 1, 0, 0xAA, 0xAA, 0xAA, 0xBB, 0xBB, 0xCC, 0xDD,
  ]
  debug_inspect(@header.parse_jump_table(table[:]), content="Ok((3, 2, 1, 1))")
  inspect(@header.le16(table[:], 0), content="3")
  inspect(@header.le16(table[:], 12), content="221")
  inspect(@header.byte_at(table[:], -1), content="0")
  inspect(@header.byte_at(table[:], 13), content="0")
}
