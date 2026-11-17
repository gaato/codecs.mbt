///|
test "HQ dictionary lookup follows prefix, suffix and uppercase guards" {
  let lookup = HqDictionary::new()
  let mut identity = b""
  let mut upper = b""
  for packed in lookup.words {
    let length = (packed & 31U).reinterpret_as_int()
    let kind = ((packed >> 8) & 255U).reinterpret_as_int()
    let id = (packed >> 16).reinterpret_as_int()
    if length < 4 {
      continue
    }
    let offset = dictionary_offsets[length] + length * id
    if kind == 0 && identity.is_empty() {
      identity = dictionary[offset:offset + length].to_owned()
    }
    if kind == 10 && upper.is_empty() {
      upper = Bytes::makei(length, i => {
        (if i == 0 {
          dictionary[offset + i].to_int() ^ 32
        } else {
          dictionary[offset + i].to_int()
        }).to_byte()
      })
    }
    if !identity.is_empty() && !upper.is_empty() {
      break
    }
  }
  assert_false(identity.is_empty())
  assert_false(upper.is_empty())
  for
    (word, size) in [
      (upper + b" testing more", upper.length()),
      (b" " + upper + b" testing more", upper.length() + 1),
      (b"." + identity + b" testing more", identity.length() + 1),
      (b"s " + identity + b" testing more", identity.length() + 3),
    ] {
    let data = FixedArray::makei(word.length(), i => word[i])
    lookup.find(data, 0, 4, word.length())
    assert_true(lookup.matches[size] < 0xfffffff)
  }
  // IsMatch rejects an uppercase-first LUT entry for a base word whose
  // first byte is not an ASCII lowercase letter, even when bytes agree.
  let mut checked = false
  for id in 0..<(1 << dictionary_size_bits[4]) {
    let offset = dictionary_offsets[4] + 4 * id
    let first = dictionary[offset]
    if first < b'a' || first > b'z' {
      let data = FixedArray::makei(4, i => dictionary[offset + i])
      assert_eq(hq_word_match(data, 0, 4, 4, id, 10), 0)
      checked = true
      break
    }
  }
  assert_true(checked)
  let data = FixedArray::makei(32, i => i.to_byte())
  let tree = HqTree::new(10, 32, false)
  tree.find(data, 10, 10U, 4, 2, 2, 10)
  assert_eq(tree.count, 0)
}

///|
test "HQ distance parameter search keeps original valid long codes" {
  let raw = MAX_CODED_DISTANCE + 15
  let commands = [RefCommand::new(0, 4, 0, raw)]
  let (direct, post) = hq_distance_params(commands)
  assert_eq((direct, post), (120, 3))
  let (symbol, extra, bits) = hq_distance(raw, direct, post)
  assert_true(symbol < 16 + direct + (48 << post))
  let high = (symbol - 16 - direct) >> post
  let low = (symbol - 16 - direct) & ((1 << post) - 1)
  let offset = ((2 + (high & 1)) << bits) - 4
  assert_eq(((offset + extra) << post) + low + direct + 16, raw)
}

///|
test "HQ clustering enforces the histogram cap with reference tie order" {
  // Each adjacent symbol pair is distinct and costs more to merge than
  // to keep. The 257th histogram forces one merge; equal reductions prefer
  // the first adjacent pair. Counts must survive remapping and reindexing.
  let input = Array::makei(257, i => {
    let h = HqHistogram::new(256)
    for _ in 0..<100 {
      h.add(i % 256)
      h.add((i + 1 + i / 256) % 256)
    }
    h
  })
  let (out, map) = hq_cluster(input)
  assert_eq(out.length(), 256)
  assert_eq(map[0], 0)
  assert_eq(map[1], 0)
  for i in 2..<257 {
    assert_eq(map[i], i - 1)
  }
  assert_eq(out.fold(init=0, (n, h) => n + h.total), 51400)
  assert_eq(out[0].data[0], 100)
  assert_eq(out[0].data[1], 200)
  assert_eq(out[0].data[2], 100)
}

///|
test "HQ pair capacity applies its linear cap without Int32 overflow" {
  for n in [0, 1, 2, 64, 256, 65536, 16777216] {
    let wide = n.to_int64()
    assert_eq(hq_max_pairs(n).to_int64(), (64L * wide).min(wide / 2L * wide))
  }
}

///|
test "HQ context maps round trip zero runs beyond the RLE prefix cap" {
  // Four block types already permit a run longer than 127; the largest
  // map exercises repeated capped runs and a final nonzero MTF entry.
  for types in [4, 256] {
    let map = FixedArray::make(64 * types, 0)
    map[map.length() - 1] = 1
    let writer = @bits.BitPacker()
    ref_write_map(writer, map, 2)
    writer.align()
    let encoded = FixedArray::make(writer.pending(), b'\x00')
    assert_eq(writer.drain_into(encoded, 0), encoded.length())
    let bytes = Bytes::from_array(encoded)
    let decoder = Decoder()
    decoder.state = NumTrees
    decoder.cat = 0
    decoder.num_types[0] = types
    decoder.view = bytes[:]
    let mut units = 0
    while decoder.cat == 0 {
      assert_true(units < map.length() + 100)
      assert_true(decoder.unit() is None)
      units += 1
    }
    assert_eq(decoder.cat, 2)
    assert_true(decoder.state is NumTrees)
    assert_eq(decoder.lit_trees_count, 2)
    assert_eq(decoder.map_rle_max, 6)
    for i in 0..<map.length() {
      assert_eq(decoder.lit_context_map[i].to_int(), map[i])
    }
  }
}
