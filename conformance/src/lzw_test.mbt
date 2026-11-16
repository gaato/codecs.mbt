///|
/// The format of an LZW vector's set, the part of its name after the dot.
fn lzw_format(set : String) -> @lzw.Format raise {
  match set {
    "gif-2" => @lzw.Format::gif(2)
    "gif-4" => @lzw.Format::gif(4)
    "gif-8" => @lzw.Format::gif(8)
    "tiff" => @lzw.Format::tiff()
    "msb" => @lzw.Format::pdf(early_change=false)
    "z12" => @lzw.Format::unix_compress(max_bits=12)
    "z10" => @lzw.Format::unix_compress(max_bits=10)
    _ => @lzw.Format::unix_compress()
  }
}

///|
/// The vectors of one set.
fn lzw_set(set : String) -> Array[Vector] {
  lzw_vectors.filter(v => v.name.has_suffix(".\{set}"))
}

///|
test "lzw keeps the byte-stream contract" {
  // GIF, TIFF and PDF end at their end code: any byte after it is
  // trailing, and each vector is one member.
  for set in ["gif-2", "gif-4", "gif-8", "tiff", "msb"] {
    let format = lzw_format(set)
    conform(
      "lzw \{set}",
      lzw_set(set),
      (_, until) => @lzw.Decoder(format, until~),
      memory_limit=_ => @lzw.decoder_memory_bound(format).to_int(),
      garbage=[b"\x00", b"\xff\xff\xff\xff"],
      one_member=_ => true,
    )
  }
}

///|
test ".Z keeps the parts of the contract a stream without an end code can" {
  // .Z ends with the input, and every byte after a stream is read as more
  // codes: there is no trailing data to refuse and no member to stop at.
  // Splits must agree, and prefixes end cleanly or are refused alike.
  for set in ["z16", "z12", "z10"] {
    let format = lzw_format(set)
    let limit = Some(@lzw.decoder_memory_bound(format).to_int())
    for v in lzw_set(set) {
      let input = v.input()
      let codec = () => @codec_harness.ByteDecoder::new(@lzw.Decoder(format))
      let whole = @codec_harness.check_splits(codec, input, memory_limit=limit) catch {
        e => fail("lzw \{set} \{v.name}: \{e}")
      }
      if whole.error is Some(_) ||
        whole.output.length() != v.size ||
        @codec_harness.sha256(whole.output) != v.sha256 {
        fail("lzw \{set} \{v.name}: does not decode to its original")
      }
      @codec_harness.check_truncation(codec, input, whole, max_prefixes=64) catch {
        e => fail("lzw \{set} \{v.name}: \{e}")
      }
    }
  }
}

///|
test "corrupted lzw streams never break the contract" {
  for set in ["gif-8", "tiff", "z16"] {
    let format = lzw_format(set)
    let holding = lzw_set(set).filter(v => v.size > 0)
    for v in holding[:holding.length().min(4)] {
      let codec = () => @codec_harness.ByteDecoder::new(@lzw.Decoder(format))
      let _ = @codec_harness.fuzz(
        codec,
        v.input(),
        seed=12,
        rounds=200,
        memory_limit=Some(@lzw.decoder_memory_bound(format).to_int()),
      )
    }
  }
}

///|
test "the lzw encoder keeps the byte-stream contract" {
  let rng = @codec_harness.Rng::new(12)
  let text = (n : Int32) => {
    let words = ["the ", "lzw ", "code ", "table ", "of ", "a ", "\n"]
    let out = Buffer()
    while out.length() < n {
      out.write_string_utf8(words[rng.below(words.length())])
    }
    out.to_bytes()[:n].to_owned()
  }
  let inputs = [b"", b"x", text(5000), text(60000)]
  for set in ["gif-8", "tiff", "z16", "z10"] {
    let format = lzw_format(set)
    for input in inputs {
      let _ = @codec_harness.check_roundtrip(
        () => @lzw.Encoder(format),
        () => @lzw.Decoder(format),
        input,
        encoder_memory_limit=Some(@lzw.encoder_memory_bound(format).to_int()),
        decoder_memory_limit=Some(@lzw.decoder_memory_bound(format).to_int()),
        small=20000,
      ) catch {
        e => fail("lzw encoder \{set}: \{e}")
      }
    }
    let wrapped = () => @codec_harness.ByteEncoder::new(@lzw.Encoder(format))
    @codec_harness.check_reset(wrapped, inputs[2], inputs[3]) catch {
      e => fail("lzw encoder \{set} reset: \{e}")
    }
  }
}
