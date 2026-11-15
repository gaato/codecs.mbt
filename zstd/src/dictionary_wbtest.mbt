///|
/// The kind of error decoding `input` with `dictionary` raises.
fn dict_refusal(
  input : BytesView,
  dictionary? : Dictionary,
) -> @codec.ErrorKind raise {
  try decompress(input, dictionary?) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
}

///|
test "zstd -D frames with a raw dictionary decode to their input" {
  let raw = Dictionary::raw(dict_bytes("raw"))
  let mut n = 0
  for v in dict_vectors {
    guard v.dictionary == "raw" else { continue }
    let got = decompress(v.input(), dictionary=raw)
    assert_eq(got.length(), v.size, msg=v.name)
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
    n += 1
  }
  assert_true(n >= 20)
}

///|
test "a frame that names a dictionary needs that one" {
  let raw = Dictionary::raw(dict_bytes("raw"))
  for v in dict_vectors {
    guard v.dictionary == "trained" && v.size > 0 else { continue }
    // The trained dictionary's id is 1234567.
    assert_eq(dict_refusal(v.input()), DictionaryRequired(Some(1234567)))
    assert_eq(dict_refusal(v.input(), dictionary=raw), DictionaryMismatch)
  }
  // A frame that reaches into the dictionary, decoded without it.
  let v = dict_vectors[dict_vectors
    .search_by(v => v.name == "raw/record_level3")
    .unwrap()]
  assert_eq(dict_refusal(v.input()), Corrupt)
  // A dictionary given to frames that name none and need none changes
  // nothing.
  let plain = vector("gen/text_level3")
  let got = decompress(plain.input(), dictionary=raw)
  assert_eq(@checksum.sha256(got), plain.sha256)
}

///|
test "dictionary frames: any input split and output size give the same output" {
  let raw = Dictionary::raw(dict_bytes("raw"))
  for v in dict_vectors {
    guard v.dictionary == "raw" && v.size <= 5000 else { continue }
    let input = v.input()
    for split in [(1, 1), (1, 1 << 16), (7, 3), (4096, 64)] {
      let (in_chunk, out_chunk) = split
      let next_out = () => out_chunk
      let got = drive(
        Decoder(dictionary=raw),
        input,
        next_in=() => in_chunk,
        next_out~,
      )
      assert_eq(
        @checksum.sha256(got),
        v.sha256,
        msg="\{v.name} \{in_chunk} \{out_chunk}",
      )
    }
  }
}

///|
/// A decoder with `dictionary`, set up as at the start of a frame's first
/// block with a window of `window` bytes.
fn frame_start(dictionary : Bytes, window : Int32) -> Decoder {
  let d = Decoder(dictionary=Dictionary::raw(dictionary))
  d.window = window
  d.ring_max = window
  d.block_max = window
  d.wpos = 0
  d.filled = 0
  d.frame_out = 0
  d.block_out = 0
  d
}

///|
/// The output of `d` so far, from the frame's start.
fn dict_written(d : Decoder) -> Bytes {
  Bytes::from_array(d.ring[:d.wpos])
}

///|
test "copy_from_dictionary: the dictionary's end, its last byte, and past it" {
  // `p + D` back reaches the dictionary's first byte; one more is refused.
  let d = frame_start(b"ABCDEFGH", 1024)
  d.copy_from_dictionary(8, 3)
  assert_eq(dict_written(d), b"ABC")
  // Now p = 3: 11 back is the dictionary's first byte, 12 is before it.
  d.copy_from_dictionary(11, 1)
  assert_eq(dict_written(d), b"ABCA")
  let refused = try d.copy_from_dictionary(13, 1) catch {
    Fail(kind, _) => Some(kind)
    _ => None
  } noraise {
    _ => None
  }
  assert_eq(refused, Some(Corrupt))
  // A match from the dictionary's end that runs on into the output: three
  // bytes from the dictionary, then the frame's first two.
  let d = frame_start(b"ABCDEFGH", 1024)
  d.copy_from_dictionary(3, 5)
  assert_eq(dict_written(d), b"FGHFG")
  // An offset of 0, or with no dictionary bytes to reach, is refused.
  let d = frame_start(b"", 1024)
  let refused = try d.copy_from_dictionary(1, 1) catch {
    Fail(kind, _) => Some(kind)
    _ => None
  } noraise {
    _ => None
  }
  assert_eq(refused, Some(Corrupt))
}

///|
test "copy_from_dictionary: the dictionary stays reachable past the window" {
  // Two blocks' worth of output in a 16-byte window, then a match into the
  // dictionary, as zstd's decoder allows.
  let d = frame_start(b"0123456789", 16)
  d.frame_out = 40
  d.filled = 16
  d.copy_from_dictionary(42, 2)
  assert_eq(dict_written(d), b"89")
  // A match that would run on from the dictionary's last byte into the
  // frame's start, 43 bytes back and past the window, is refused.
  let refused = try d.copy_from_dictionary(43, 3) catch {
    Fail(kind, _) => Some(kind)
    _ => None
  } noraise {
    _ => None
  }
  assert_eq(refused, Some(Corrupt))
}

///|
test "a dictionary is not counted in memory_usage" {
  let raw = Dictionary::raw(dict_bytes("raw"))
  for v in dict_vectors {
    guard v.dictionary == "raw" && v.name.has_suffix("level3") else { continue }
    let plain = Decoder()
    let with_dict = Decoder(dictionary=raw)
    let _ = drive(with_dict, v.input(), next_in=() => 1 << 20, next_out=() => {
      1 << 20
    })
    assert_true(with_dict.memory_usage() <= memory_bound(27), msg=v.name)
    assert_eq(plain.memory_usage(), Decoder().memory_usage())
  }
}

///|
test "zstd -D frames with a trained dictionary decode to their input" {
  let trained = Dictionary::parse(dict_bytes("trained"))
  assert_true(trained.is_formatted())
  assert_eq(trained.id(), 1234567)
  let mut n = 0
  for v in dict_vectors {
    guard v.dictionary == "trained" else { continue }
    let got = decompress(v.input(), dictionary=trained)
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
    for split in [(1, 1), (7, 3), (4096, 64)] {
      let (in_chunk, out_chunk) = split
      guard v.size <= 5000 else { break }
      let next_out = () => out_chunk
      let got = drive(
        Decoder(dictionary=trained),
        v.input(),
        next_in=() => in_chunk,
        next_out~,
      )
      assert_eq(@checksum.sha256(got), v.sha256, msg="\{v.name} \{in_chunk}")
    }
    n += 1
  }
  assert_true(n >= 20)
  // Parsed as raw, the same bytes are another dictionary, which the frames
  // do not name.
  let v = dict_vectors[dict_vectors
    .search_by(v => v.name == "trained/record_level3")
    .unwrap()]
  assert_eq(
    dict_refusal(v.input(), dictionary=Dictionary::raw(dict_bytes("trained"))),
    DictionaryMismatch,
  )
}

///|
test "formatted dictionaries that do not parse are Corrupt" {
  let good = dict_bytes("trained")
  let kind = (data : Bytes) => {
    try Dictionary::parse(data) catch {
      CodecError(kind, _) => Some(kind)
    } noraise {
      _ => None
    }
  }
  assert_eq(kind(good), None)
  // Cut inside the entropy tables, and before the repeat offsets end.
  for cut in [8, 9, 20, 60] {
    assert_eq(kind(good[:cut].to_owned()), Some(Corrupt), msg="\{cut}")
  }
  // The magic number alone, and a header without it, are raw content.
  assert_eq(kind(good[:7].to_owned()), None)
  assert_false(Dictionary::parse(good[1:]).is_formatted())
  // A repeat offset of 0, and one past the content. Find where the
  // offsets are: the content is what follows them.
  let parsed = Dictionary::parse(good)
  let at = good.length() - parsed.content().length() - 12
  let zero = good.to_fixedarray()
  for i in 0..<4 {
    zero[at + i] = b'\x00'
  }
  assert_eq(kind(Bytes::from_array(zero)), Some(Corrupt))
  let far = good.to_fixedarray()
  far[at + 7] = b'\x7f'
  assert_eq(kind(Bytes::from_array(far)), Some(Corrupt))
}
