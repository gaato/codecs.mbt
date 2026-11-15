///|
/// The bound gaato/lz4 gives for a decoder's `memory_usage`.
fn lz4_decoder_limit(_window_bits : Int32) -> Int32 {
  @lz4.decoder_memory_bound().to_int()
}

///|
test "lz4 keeps the byte-stream contract" {
  // Four 0xFF bytes begin no frame, after a frame or a legacy block (whose
  // size they would pass); zeros after a legacy frame would be an empty
  // block, so they are not garbage here. Every vector is a whole stream; a
  // legacy frame ends only with what follows it, and refuses EndOfMember.
  conform(
    "lz4",
    lz4_vectors,
    (_, until) => @lz4.Decoder(until~),
    memory_limit=lz4_decoder_limit,
    garbage=[b"\xff\xff\xff\xff\xff\xff\xff\xff"],
    one_member=v => !v.name.has_suffix(".legacy"),
  )
}

///|
test "corrupted lz4 streams never break the contract" {
  let holding = lz4_vectors.filter(v => v.size > 0)
  for v in holding[:holding.length().min(8)] {
    let codec = () => @codec_harness.ByteDecoder::new(@lz4.Decoder())
    let _ = @codec_harness.fuzz(
      codec,
      v.input(),
      seed=4,
      rounds=200,
      memory_limit=Some(lz4_decoder_limit(0)),
    )
  }
}

///|
/// Inputs for the encoder: empty, one byte, text, random bytes, a repeated
/// pattern, and more than two 64 KiB blocks of mixed data.
fn lz4_encoder_inputs() -> Array[(String, Bytes)] {
  let rng = @codec_harness.Rng::new(4)
  let random = (n : Int32) => {
    Bytes::makei(n, _ => (rng.below(1 << 16) >> 8).to_byte())
  }
  let text = (n : Int32) => {
    let words = ["the ", "lz4 ", "block ", "frame ", "of ", "a ", "\n"]
    let out = Buffer()
    while out.length() < n {
      out.write_string_utf8(words[rng.below(words.length())])
    }
    out.to_bytes()[:n].to_owned()
  }
  [
    ("empty", b""),
    ("one byte", b"x"),
    ("text", text(5000)),
    ("random", random(3000)),
    ("repetitive", b"abcabcabd".repeat(2000)),
    ("large", text(100000) + random(70000) + text(60000)),
  ]
}

///|
test "the lz4 encoder keeps the byte-stream contract" {
  let options : Array[(String, () -> @lz4.Encoder)] = [
    ("linked", () => @lz4.Encoder()),
    ("independent", () => @lz4.Encoder(linked=false, block_checksum=true)),
    ("256 KiB, fast", () => @lz4.Encoder(block_size=Max256KiB, acceleration=8)),
  ]
  let decoder = () => @lz4.Decoder()
  for option in options {
    let (label, encoder) = option
    let limit = Some(@lz4.encoder_memory_bound(block_size=Max256KiB).to_int())
    for named in lz4_encoder_inputs() {
      let (name, input) = named
      let label = "lz4 encoder \{label} \{name}"
      let _ = @codec_harness.check_roundtrip(
        encoder,
        decoder,
        input,
        encoder_memory_limit=limit,
        decoder_memory_limit=Some(lz4_decoder_limit(0)),
        small=20000,
      ) catch {
        e => fail("\{label}: \{e}")
      }
      // Before any input, after one byte, twice at the same place, and at
      // the end.
      let n = input.length()
      let flush_at = [0, n.min(1), n / 3, n / 3, n / 2, n]
      flush_at.sort()
      @codec_harness.check_flush(encoder, decoder, input, flush_at~) catch {
        e => fail("\{label} flush: \{e}")
      }
    }
    let inputs = lz4_encoder_inputs()
    let wrapped = () => @codec_harness.ByteEncoder::new(encoder())
    @codec_harness.check_reset(wrapped, inputs[2].1, inputs[3].1) catch {
      e => fail("lz4 encoder \{label} reset: \{e}")
    }
  }
}
