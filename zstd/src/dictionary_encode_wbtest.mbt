///|
/// The inputs of the dictionary vectors, decoded from `zstd -D`'s frames:
/// records that share words with the raw dictionary.
fn dict_inputs() -> Array[(String, Bytes)] raise {
  let raw = Dictionary::raw(dict_bytes("raw"))
  let inputs = []
  for v in dict_vectors {
    if v.dictionary == "raw" && v.name.has_suffix("_level3") {
      inputs.push((v.name, decompress(v.input(), dictionary=raw)))
    }
  }
  inputs
}

///|
test "frames made with a dictionary decode with it, and are smaller" {
  let raw = Dictionary::raw(dict_bytes("raw"))
  let inputs = dict_inputs()
  assert_true(inputs.length() >= 5)
  for named in inputs {
    let (name, input) = named
    for level in [-5, -1, 1, 2, 3, 4, 5, 6, 8, 9, 12] {
      let frame = compress(input, level~, dictionary=raw)
      assert_eq(
        decompress(frame, dictionary=raw),
        input,
        msg="\{name} \{level}",
      )
      if input.length() >= 300 {
        assert_true(
          frame.length() < compress(input, level~).length(),
          msg="\{name} \{level}",
        )
      }
      // Of unknown size, streamed.
      let streamed = encode_drive(
        Encoder(level~, dictionary=raw),
        input,
        next_in=() => 999,
        next_out=() => 4096,
      )
      assert_eq(
        decompress(streamed, dictionary=raw),
        input,
        msg="streamed \{name} \{level}",
      )
    }
  }
}

///|
test "a dictionary frame's bytes do not depend on how the input is split" {
  let raw = Dictionary::raw(dict_bytes("raw"))
  for named in dict_inputs() {
    let (name, input) = named
    for level in [1, 3, 5, 12] {
      let whole = encode_drive(
        Encoder(level~, dictionary=raw),
        input,
        next_in=() => 1 << 20,
        next_out=() => 1 << 20,
      )
      for chunk in [1, 7, 4096] {
        let next_in = () => chunk
        let split = encode_drive(
          Encoder(level~, dictionary=raw),
          input,
          next_in~,
          next_out=() => 333,
        )
        assert_eq(split, whole, msg="\{name} \{level} \{chunk}")
      }
      // A reset encoder writes the same frame again.
      let encoder = Encoder(level~, dictionary=raw)
      let first = encode_drive(encoder, input, next_in=() => 4096, next_out=() => {
        4096
      })
      encoder.reset()
      let second = encode_drive(encoder, input, next_in=() => 4096, next_out=() => {
        4096
      })
      assert_eq(first, second, msg="reset \{name} \{level}")
    }
  }
}

///|
test "the dictionary goes out of reach a window past it" {
  // Level 1 without a size has a 512 KiB window: past it, the encoder no
  // longer reaches into the dictionary, and the decoder needs only the
  // window to follow.
  let raw = Dictionary::raw(dict_bytes("raw"))
  let input = Buffer()
  for named in dict_inputs() {
    input.write_bytes(named.1)
  }
  let one = input.to_bytes()
  let long = Buffer()
  while long.length() < 1200000 {
    long.write_bytes(one)
  }
  let long = long.to_bytes()
  for level in [1, 3, 5] {
    let frame = encode_drive(
      Encoder(level~, dictionary=raw),
      long,
      next_in=() => 65536,
      next_out=() => 65536,
    )
    assert_eq(decompress(frame, dictionary=raw), long, msg="\{level}")
  }
}

///|
test "without a dictionary, the parameters are those of before" {
  for level in [-5, 1, 3, 5, 9, 12] {
    for size in [None, Some(100L), Some(20000L), Some(200000L), Some(1L << 31)] {
      assert_eq(
        complete_row(params_for(level, size, dict_size=0)),
        complete_row(params_for(level, size)),
      )
    }
  }
  // With one, the table is that of the input and the dictionary together,
  // and an unknown size counts as 499 bytes, as zstd's unsigned sum makes
  // it: 60,499 bytes, the table for at most 128 KiB, its row as it is.
  let p = params_for(3, None, dict_size=60000)
  assert_eq(complete_row(p), complete_row(level_tables[2][2]))
  // At each size class's edge: 16, 128 and 256 KiB.
  for edge in [16384, 131072, 262144] {
    let table = (if edge <= 262144 { 1 } else { 0 }) +
      (if edge <= 131072 { 1 } else { 0 }) +
      (if edge <= 16384 { 1 } else { 0 })
    let at = params_for(3, None, dict_size=edge - 499)
    let past = params_for(3, None, dict_size=edge - 498)
    assert_eq(
      complete_row(at),
      complete_row(level_tables[table][2]),
      msg="\{edge}",
    )
    assert_eq(
      complete_row(past),
      complete_row(level_tables[table - 1][2]),
      msg="\{edge} + 1",
    )
  }
  let p = params_for(3, Some(1000L), dict_size=60000)
  assert_true(p.window_log >= 16)
  // The encoder keeps at most the last 512 MiB of a dictionary.
  assert_eq(encoder_view(b"abc"[:]).length(), 3)
}

///|
test "a trained dictionary: its id in the header, its tables from the first block" {
  let trained = Dictionary::parse(dict_bytes("trained"))
  let content_only = Dictionary::raw(trained.content())
  let mut with_tables = 0
  let mut without = 0
  for named in dict_inputs() {
    let (name, input) = named
    for level in [-1, 1, 3, 5, 9, 12] {
      let frame = compress(input, level~, dictionary=trained)
      guard inspect_frame(frame) is Zstd(info) else { fail("not a frame") }
      assert_eq(info.dictionary_id, 1234567U, msg=name)
      assert_eq(
        decompress(frame, dictionary=trained),
        input,
        msg="\{name} \{level}",
      )
      let streamed = encode_drive(
        Encoder(level~, dictionary=trained),
        input,
        next_in=() => 777,
        next_out=() => 4096,
      )
      assert_eq(
        decompress(streamed, dictionary=trained),
        input,
        msg="streamed \{name} \{level}",
      )
      with_tables += frame.length()
      without += compress(input, level~, dictionary=content_only).length()
    }
  }
  // The dictionary's tables and repeat offsets pay on small records.
  assert_true(with_tables < without, msg="\{with_tables} \{without}")
}

///|
test "tables for a dictionary the window does not hold with the input" {
  // A 4 MiB input and a 2 MiB dictionary at level 1 (a 512 KiB window):
  // the tables hold the dictionary and the window, 2^22 bytes, so hashLog
  // is capped at 23, above the row's 14, and nothing changes.
  let p = params_for(1, Some(4L << 20), dict_size=2 << 20)
  assert_eq(p.window_log, 19)
  assert_eq(p.hash_log, 14)
  // A dictionary of 2^31 - 1 bytes: zstd's largest window log, 31.
  let p = params_for(3, Some(1L << 20), dict_size=0x7fffffff)
  assert_eq(p.window_log, 21)
  assert_eq(p.hash_log, 17)
}

///|
test "formatted dictionaries with ids of one and two bytes" {
  let good = dict_bytes("trained")
  for id in [200U, 40000U] {
    let bytes = good.to_fixedarray()
    for i in 0..<4 {
      bytes[4 + i] = (id >> (8 * i)).to_byte()
    }
    let dict = Dictionary::parse(Bytes::from_array(bytes))
    assert_eq(dict.id(), id)
    let input = Bytes::makei(2000, i => (b'a'.to_int() + i % 26).to_byte())
    let frame = compress(input, dictionary=dict)
    guard inspect_frame(frame) is Zstd(info) else { fail("not a frame") }
    assert_eq(info.dictionary_id, id)
    assert_eq(info.header_len, 4 + 1 + (if id < 256 { 1 } else { 2 }) + 2)
    assert_eq(decompress(frame, dictionary=dict), input)
  }
}
