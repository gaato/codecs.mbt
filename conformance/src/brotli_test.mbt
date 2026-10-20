///|
/// The most bytes of prefix code tables a brotli decoder holds, as
/// brotli/RESOURCE_BOUNDS.md gives them.
const BROTLI_TABLE_BYTES : Int32 = 1343596

///|
/// The bound brotli/RESOURCE_BOUNDS.md gives for a decoder's
/// `memory_usage`: the window `max_window_bits` allows, and the tables.
fn brotli_decoder_limit(max_window_bits : Int32) -> Int32? {
  Some((1 << max_window_bits) + BROTLI_TABLE_BYTES)
}

///|
/// The bound brotli/RESOURCE_BOUNDS.md gives for an encoder's
/// `memory_usage`: the input buffer at its largest, and its waiting output.
fn brotli_encoder_limit(window_bits : Int32) -> Int32? {
  Some(
    (1 << window_bits) -
    16 +
    (1 << (window_bits - 2)).max(1 << 16) +
    (1 << 16) +
    2 * ((1 << 16) + 64),
  )
}

///|
test "brotli keeps the byte-stream contract" {
  // `conform`'s checks, with the decoder's memory bound after every step.
  // Brotli has no framing: any byte after the stream is trailing.
  let garbage = [b"\x00", b"\xff\xff\xff\xff\xff\xff\xff\xff"]
  for v in brotli_vectors {
    let input = v.input()
    let codec = () => {
      @codec_harness.ByteDecoder::new(
        @brotli.Decoder(max_window_bits=v.window_bits),
      )
    }
    let label = "brotli \{v.name}"
    let whole = @codec_harness.check_splits(
      codec,
      input,
      memory_limit=brotli_decoder_limit(v.window_bits),
    ) catch {
      e => fail("\{label}: \{e}")
    }
    if whole.error is Some(_) ||
      whole.output.length() != v.size ||
      @codec_harness.sha256(whole.output) != v.sha256 {
      fail("\{label}: does not decode to its original")
    }
    @codec_harness.check_truncation(codec, input, whole, max_prefixes=64) catch {
      e => fail("\{label}: \{e}")
    }
    @codec_harness.check_trailing(codec, input, garbage~) catch {
      e => fail("\{label}: \{e}")
    }
  }
  let first = brotli_vectors[0].input()
  let last = brotli_vectors[brotli_vectors.length() - 1].input()
  let wide = () => @codec_harness.ByteDecoder::new(@brotli.Decoder())
  @codec_harness.check_reset(wide, last, first) catch {
    e => fail("brotli reset: \{e}")
  }
}

///|
test "corrupted brotli streams never break the contract" {
  for v in brotli_vectors[:8] {
    let codec = () => @codec_harness.ByteDecoder::new(@brotli.Decoder())
    let _ = @codec_harness.fuzz(
      codec,
      v.input(),
      seed=7932,
      rounds=200,
      memory_limit=brotli_decoder_limit(24),
    )
  }
}

///|
/// Inputs for the encoder: empty, one byte, text, random bytes, a repeated
/// pattern, and more than a 64 KiB meta-block of mixed data.
fn brotli_encoder_inputs() -> Array[(String, Bytes)] {
  let rng = @codec_harness.Rng::new(7932)
  let random = (n : Int32) => {
    Bytes::makei(n, _ => (rng.below(1 << 16) >> 8).to_byte())
  }
  let text = (n : Int32) => {
    let words = ["the ", "brotli ", "stream ", "window ", "of ", "a ", "\n"]
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
test "the brotli encoder keeps the byte-stream contract" {
  for window_bits in [16, 22] {
    let encoder = () => @brotli.Encoder(window_bits~)
    let decoder = () => @brotli.Decoder()
    for named in brotli_encoder_inputs() {
      let (name, input) = named
      let label = "brotli encoder w\{window_bits} \{name}"
      let _ = @codec_harness.check_roundtrip(
        encoder,
        decoder,
        input,
        encoder_memory_limit=brotli_encoder_limit(window_bits),
        decoder_memory_limit=brotli_decoder_limit(24),
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
    let inputs = brotli_encoder_inputs()
    let wrapped = () => @codec_harness.ByteEncoder::new(encoder())
    @codec_harness.check_reset(wrapped, inputs[2].1, inputs[3].1) catch {
      e => fail("brotli encoder w\{window_bits} reset: \{e}")
    }
  }
}
