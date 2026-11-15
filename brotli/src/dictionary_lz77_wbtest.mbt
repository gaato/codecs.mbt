///|
/// The dictionary in `dict_content`.
fn lz77_dictionary() -> Dictionary {
  let bytes = @base64.decode(dict_content, ignore_whitespace=true) catch {
    _ => abort("bad base64 in dict_content")
  }
  Dictionary(bytes)
}

///|
/// A stream that copies from an LZ77 dictionary, made by `brotli -D`
/// (brotli/scripts/gen_dict_vectors.mbtx).
priv struct DictVector {
  name : String
  compressed : String
  size : Int32
  sha256 : String
}

///|
fn DictVector::input(self : DictVector) -> Bytes {
  @base64.decode(self.compressed, ignore_whitespace=true) catch {
    _ => abort("bad base64 in vector \{self.name}")
  }
}

///|
test "brotli -D streams decode with the dictionary, however split" {
  let dict = lz77_dictionary()
  for v in dict_vectors {
    let got = decompress(v.input(), dictionary=dict)
    assert_eq(got.length(), v.size, msg=v.name)
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
    guard v.size <= 5000 else { continue }
    for split in [(1, 1), (7, 3), (4096, 64)] {
      let (in_chunk, out_chunk) = split
      let next_out = () => out_chunk
      let got = drive(
        Decoder(dictionary=dict),
        v.input(),
        next_in=() => in_chunk,
        next_out~,
      )
      assert_eq(@checksum.sha256(got), v.sha256, msg="\{v.name} \{in_chunk}")
    }
  }
}

///|
test "without the dictionary, a stream that copies from it is refused" {
  let mut refused = 0
  for v in dict_vectors {
    guard v.size > 0 else { continue }
    let outcome = try decompress(v.input()) catch {
      CodecError(Corrupt, _) => 1
      _ => 2
    } noraise {
      got => if @checksum.sha256(got) == v.sha256 { 0 } else { 2 }
    }
    // Qualities 0 and 1 do not use a dictionary, so their streams decode
    // the same without it; the others that reach into it are refused, or
    // read static dictionary words where the dictionary was meant and come
    // out different.
    if v.name.contains("_q0_") || v.name.contains("_q1_") {
      continue
    }
    refused += if outcome == 1 { 1 } else { 0 }
  }
  assert_true(refused > 0)
}

///|
test "lz77_address: the dictionary from its end, static words after it" {
  let address = (dist, filled, dict_len, copy_len) => {
    lz77_address(dist, filled, dict_len, copy_len) catch {
      Fail(Corrupt, _) => -2
      _ => -3
    }
  }
  // Just past the window's reach: the dictionary's last byte.
  assert_eq(address(101, 100, 50, 1), 49)
  // dict_len past it: the dictionary's first byte, a copy of all of it.
  assert_eq(address(150, 100, 50, 50), 0)
  // One further: a static dictionary word.
  assert_eq(address(151, 100, 50, 4), -1)
  // A copy past the dictionary's end is refused.
  assert_eq(address(101, 100, 50, 2), -2)
  assert_eq(address(150, 100, 50, 51), -2)
  // Without a dictionary, every distance past the reach is a word.
  assert_eq(address(101, 100, 0, 4), -1)
}

///|
/// The inputs of the dictionary vectors: records that share words with the
/// dictionary.
fn dict_inputs() -> Array[(String, Bytes)] raise {
  let dict = lz77_dictionary()
  let inputs = []
  for v in dict_vectors {
    if v.name.has_suffix("_q5_w22") || v.name.has_suffix("_q11_w22") {
      inputs.push((v.name, decompress(v.input(), dictionary=dict)))
    }
  }
  inputs
}

///|
test "streams made with a dictionary decode with it, reach into it, and are smaller" {
  let dict = lz77_dictionary()
  let mut reached = 0
  for named in dict_inputs() {
    let (name, input) = named
    for window_bits in [10, 16, 22] {
      let stream = compress(input, window_bits~, dictionary=dict)
      assert_eq(
        decompress(stream, dictionary=dict),
        input,
        msg="\{name} \{window_bits}",
      )
      if input.length() >= 300 {
        assert_true(
          stream.length() < compress(input, window_bits~).length(),
          msg="\{name} \{window_bits}",
        )
        let without = try decompress(stream) catch {
          _ => b""
        } noraise {
          got => got
        }
        if without != input {
          reached += 1
        }
      }
    }
  }
  assert_true(reached > 0)
}

///|
/// `input` through `encoder`, `chunk` bytes per step into 333-byte slices.
fn encode_split(encoder : Encoder, input : Bytes, chunk : Int32) -> Bytes {
  let out = Buffer()
  let buffer = FixedArray::make(333, b'\x00')
  let mut pos = 0
  for ;; {
    let end = (pos + chunk).min(input.length())
    let action : EncodeAction = if end == input.length() {
      Finish
    } else {
      Continue
    }
    let mut rest = input[pos:end]
    for ;; {
      let status = encoder.step_into(rest, buffer, action~)
      rest = rest[encoder.last_consumed():]
      out.write_bytesview(
        Bytes::from_array(buffer[:encoder.last_produced()])[:],
      )
      if status is Done {
        return out.to_bytes()
      }
      if status is NeedMoreInput {
        break
      }
    }
    pos = end
  }
}

///|
test "a dictionary stream's bytes do not depend on the split; encoders share one" {
  let dict = lz77_dictionary()
  for named in dict_inputs() {
    let (name, input) = named
    let whole = encode_split(
      Encoder(window_bits=16, dictionary=dict),
      input,
      1 << 20,
    )
    for chunk in [1, 7, 4096] {
      let split = encode_split(
        Encoder(window_bits=16, dictionary=dict),
        input,
        chunk,
      )
      assert_eq(split, whole, msg="\{name} \{chunk}")
    }
    assert_eq(decompress(whole, dictionary=dict), input, msg=name)
    // A reset encoder writes the same stream again.
    let encoder = Encoder(window_bits=16, dictionary=dict)
    let first = encode_split(encoder, input, 4096)
    encoder.reset()
    assert_eq(encode_split(encoder, input, 4096), first, msg="reset \{name}")
  }
  assert_eq(Dictionary(b"abc").memory_usage(), 0)
}

///|
test "two encoders, interleaved, share one index and write the same bytes" {
  let bytes = @base64.decode(dict_content, ignore_whitespace=true)
  let dict = Dictionary(bytes)
  assert_eq(dict.memory_usage(), 0)
  let input = dict_inputs().filter(named => named.1.length() >= 4000)[0].1
  let a = Encoder(window_bits=16, dictionary=dict)
  let b = Encoder(window_bits=16, dictionary=dict)
  let out_a = Buffer()
  let out_b = Buffer()
  let buffer = FixedArray::make(4096, b'\x00')
  // A meta-block each, in turns.
  for pos = 0; pos < input.length(); pos = pos + 1000 {
    let end = (pos + 1000).min(input.length())
    let action : EncodeAction = if end == input.length() {
      Finish
    } else {
      Flush
    }
    for pair in [(a, out_a), (b, out_b)] {
      let (encoder, out) = pair
      let mut rest = input[pos:end]
      for ;; {
        let status = encoder.step_into(rest, buffer, action~)
        rest = rest[encoder.last_consumed():]
        out.write_bytesview(
          Bytes::from_array(buffer[:encoder.last_produced()])[:],
        )
        if status is (Done | NeedMoreInput) {
          break
        }
      }
    }
  }
  let index = dict.search_index()
  assert_true(physical_equal(dict.search_index(), index))
  assert_true(dict.memory_usage() > 0)
  assert_eq(out_a.to_bytes(), out_b.to_bytes())
  assert_eq(decompress(out_a.to_bytes(), dictionary=dict), input)
}
