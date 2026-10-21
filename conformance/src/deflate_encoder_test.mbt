///|
/// What gaato/deflate/RESOURCE_BOUNDS.md gives for a raw DEFLATE encoder's
/// `memory_usage`, with a dictionary or without.
let deflate_encoder_memory : Int32 = 689394

///|
/// Inputs for the encoders: empty, one byte, text, random bytes, a repeated
/// pattern, and more than four 16 KiB blocks of mixed data, past the
/// deflater's 64 KiB input ring.
fn deflate_encoder_inputs() -> Array[(String, Bytes)] {
  let rng = @codec_harness.Rng::new(1951)
  let random = (n : Int32) => {
    Bytes::makei(n, _ => (rng.below(1 << 16) >> 8).to_byte())
  }
  let text = (n : Int32) => {
    let words = ["the ", "deflate ", "stream ", "window ", "of ", "a ", "\n"]
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
/// A dictionary for the inputs above: more than the 32 KiB window, so that
/// only its end is used.
fn deflate_encoder_dictionary() -> Bytes {
  b"the deflate stream window of a\n".repeat(1200)
}

///|
/// Runs an encoder through `check_roundtrip`, `check_flush` and
/// `check_reset` over every input.
fn[E : @codec_bytes.Encode, D : @codec_bytes.Decode] check_deflate_encoder(
  label : String,
  encoder : () -> E,
  decoder : () -> D,
  encoder_memory : Int32,
  decoder_memory : Int32,
) -> Unit raise {
  let inputs = deflate_encoder_inputs()
  for named in inputs {
    let (name, input) = named
    let label = "\{label} \{name}"
    let _ = @codec_harness.check_roundtrip(
      encoder,
      decoder,
      input,
      encoder_memory_limit=Some(encoder_memory),
      decoder_memory_limit=Some(decoder_memory),
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
  let wrapped = () => @codec_harness.ByteEncoder::new(encoder())
  @codec_harness.check_reset(wrapped, inputs[5].1, inputs[2].1) catch {
    e => fail("\{label} reset: \{e}")
  }
}

///|
test "the raw DEFLATE encoder keeps the byte-stream contract" {
  for level in [0, 1, 6, 9] {
    check_deflate_encoder(
      "deflate encoder level \{level}",
      () => @deflate.Encoder(level~),
      () => @deflate.Decoder(),
      deflate_encoder_memory,
      deflate_memory,
    )
  }
  let dictionary = deflate_encoder_dictionary()
  for level in [1, 6] {
    check_deflate_encoder(
      "deflate encoder level \{level} with a dictionary",
      () => @deflate.Encoder(level~, dictionary~),
      () => @deflate.Decoder(dictionary~),
      deflate_encoder_memory,
      deflate_memory,
    )
  }
}

///|
test "the zlib encoder keeps the byte-stream contract" {
  for level in [0, 1, 6, 9] {
    check_deflate_encoder(
      "zlib encoder level \{level}",
      () => @zlib.Encoder(level~),
      () => @zlib.Decoder(),
      deflate_encoder_memory,
      deflate_memory,
    )
  }
  let dictionary = deflate_encoder_dictionary()
  check_deflate_encoder(
    "zlib encoder with a dictionary",
    () => @zlib.Encoder(dictionary~),
    () => @zlib.Decoder(dictionary~),
    deflate_encoder_memory,
    deflate_memory,
  )
}

///|
test "the gzip encoder keeps the byte-stream contract" {
  // The encoder also holds its header: 10 bytes without a name, a comment
  // or an extra field.
  for level in [0, 1, 6, 9] {
    check_deflate_encoder(
      "gzip encoder level \{level}",
      () => @gzip.Encoder(level~),
      () => @gzip.Decoder(),
      deflate_encoder_memory + 10,
      deflate_memory + 65536,
    )
  }
  let header : @gzip.Header = {
    text: true,
    mtime: 1700000000,
    xfl: b'\x00',
    os: b'\x03',
    extra: Some(b"AB\x02\x00hi"),
    name: Some(b"input.txt"),
    comment: Some(b"a comment"),
  }
  check_deflate_encoder(
    "gzip encoder with a header",
    () => @gzip.Encoder(header~),
    () => @gzip.Decoder(),
    deflate_encoder_memory + 10 + 8 + 10 + 10,
    deflate_memory + 65536,
  )
}
