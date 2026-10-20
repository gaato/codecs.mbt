// transform_word against RFC 7932 Appendix B and section 8, written from the
// RFC's pseudo-code over arrays.

///|
/// The RFC's elementary transform number of transform `t`: 0 Identity,
/// 1 FermentFirst, 2 FermentAll, 3-11 OmitFirst1-9, 12-20 OmitLast1-9.
fn rfc_transform_type(t : Int32) -> Int32 {
  let kind = transform_types[t].to_int()
  match kind {
    0 => 0
    1..<=9 => kind + 11
    10 => 1
    11 => 2
    _ => kind - 9
  }
}

///|
/// The RFC's `Ferment`: changes the case of the character at `pos` and
/// returns its length.
fn reference_ferment(word : Array[Int32], pos : Int32) -> Int32 {
  let len = word.length()
  if word[pos] < 192 {
    if word[pos] >= 97 && word[pos] <= 122 {
      word[pos] = word[pos] ^ 32
    }
    1
  } else if word[pos] < 224 {
    if pos + 1 < len {
      word[pos + 1] = word[pos + 1] ^ 32
    }
    2
  } else {
    if pos + 2 < len {
      word[pos + 2] = word[pos + 2] ^ 5
    }
    3
  }
}

///|
/// Word `index` of length `length` under transform `t`.
fn reference_transform(length : Int32, index : Int32, t : Int32) -> Bytes {
  let start = dictionary_offsets[length] + index * length
  let word = Array::makei(length, i => dictionary[start + i].to_int())
  let typ = rfc_transform_type(t)
  let word = if typ >= 3 && typ <= 11 {
    word[(typ - 2).min(length):].to_owned()
  } else if typ >= 12 {
    word[:(length - (typ - 11)).max(0)].to_owned()
  } else {
    word
  }
  if typ == 1 && word.length() > 0 {
    reference_ferment(word, 0) |> ignore
  } else if typ == 2 {
    for i = 0; i < word.length(); {
      continue i + reference_ferment(word, i)
    }
  }
  let out = Buffer()
  out.write_bytes(transform_prefixes[t])
  for b in word {
    out.write_byte(b.to_byte())
  }
  out.write_bytes(transform_suffixes[t])
  out.to_bytes()
}

///|
test "transform_word agrees with RFC 7932 for every transform of sampled words" {
  let out = FixedArray::make(MAX_TRANSFORMED_WORD + 1, b'\x00')
  let mut words = 0
  let mut multibyte = 0
  for length in 4..<=24 {
    let count = 1 << dictionary_size_bits[length]
    // Every 7th word, and the last one.
    let indices = [ for i = 0; i < count; i = i + 7 => i ]
    indices.push(count - 1)
    for index in indices {
      words += 1
      let start = dictionary_offsets[length] + index * length
      if dictionary[start:start + length].iter().any(b => b >= 192) {
        multibyte += 1
      }
      for t in 0..<NUM_TRANSFORMS {
        // A sentinel past the caller's buffer: the transform must not reach
        // it.
        out.fill(b'\xaa')
        let n = transform_word(out, length, index, t)
        assert_true(n <= MAX_TRANSFORMED_WORD)
        assert_eq(out[MAX_TRANSFORMED_WORD], b'\xaa')
        assert_eq(
          Bytes::from_array(out[:n]),
          reference_transform(length, index, t),
        )
      }
    }
  }
  inspect(words, content="1964")
  // Enough words with 2- and 3-byte characters to reach every Ferment arm.
  assert_true(multibyte > 100)
}

///|
test "transform_word: the longest word under the longest transform fills the buffer" {
  let out = FixedArray::make(MAX_TRANSFORMED_WORD, b'\x00')
  let mut longest = 0
  for t in 0..<NUM_TRANSFORMS {
    longest = longest.max(
      transform_prefixes[t].length() + transform_suffixes[t].length(),
    )
  }
  inspect(24 + longest, content="37")
  for t in 0..<NUM_TRANSFORMS {
    assert_true(transform_word(out, 24, 0, t) <= MAX_TRANSFORMED_WORD)
  }
}
