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
