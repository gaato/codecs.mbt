///|
/// The bound gaato/snappy gives for a framing decoder's `memory_usage`.
fn snappy_decoder_limit(_window_bits : Int32) -> Int32 {
  @snappy.decoder_memory_bound().to_int()
}

///|
test "snappy keeps the byte-stream contract" {
  // Nothing marks the end of a framed stream, and any four bytes are a
  // chunk's header: no bytes are garbage, and a stream followed by a
  // reserved chunk that cannot be skipped is corrupt. A stream with data
  // ends, under EndOfMember, at the identifier of the next; an empty one
  // has no data before it, so it reads the next stream as its own.
  conform(
    "snappy",
    snappy_vectors,
    (_, until) => @snappy.Decoder(until~),
    memory_limit=snappy_decoder_limit,
    garbage=[],
    broken_tail=b"\x02\x00\x00\x00",
    one_member=v => v.size > 0,
  )
}

///|
test "corrupted snappy streams never break the contract" {
  let holding = snappy_vectors.filter(v => v.size > 0)
  for v in holding[:holding.length().min(8)] {
    let codec = () => @codec_harness.ByteDecoder::new(@snappy.Decoder())
    let _ = @codec_harness.fuzz(
      codec,
      v.input(),
      seed=1100,
      rounds=200,
      memory_limit=Some(snappy_decoder_limit(0)),
    )
  }
}

///|
/// Inputs for the encoder: empty, one byte, text, random bytes, a repeated
/// pattern, and more than two 64 KiB chunks of mixed data.
fn snappy_encoder_inputs() -> Array[(String, Bytes)] {
  let rng = @codec_harness.Rng::new(1100)
  let random = (n : Int32) => {
    Bytes::makei(n, _ => (rng.below(1 << 16) >> 8).to_byte())
  }
  let text = (n : Int32) => {
    let words = ["the ", "snappy ", "chunk ", "frame ", "of ", "a ", "\n"]
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
test "the snappy encoder keeps the byte-stream contract" {
  let encoder = () => @snappy.Encoder()
  let decoder = () => @snappy.Decoder()
  let limit = Some(@snappy.encoder_memory_bound().to_int())
  for named in snappy_encoder_inputs() {
    let (name, input) = named
    let label = "snappy encoder \{name}"
    let _ = @codec_harness.check_roundtrip(
      encoder,
      decoder,
      input,
      encoder_memory_limit=limit,
      decoder_memory_limit=Some(snappy_decoder_limit(0)),
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
  let inputs = snappy_encoder_inputs()
  let wrapped = () => @codec_harness.ByteEncoder::new(encoder())
  @codec_harness.check_reset(wrapped, inputs[2].1, inputs[3].1) catch {
    e => fail("snappy encoder reset: \{e}")
  }
}
