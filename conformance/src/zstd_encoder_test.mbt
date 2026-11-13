///|
/// What gaato/zstd/RESOURCE_BOUNDS.md gives for an encoder's
/// `memory_usage`.
let zstd_encoder_memory : Int32 = 60849056

///|
/// Inputs for the encoder: empty, one byte, runs, text, random bytes, and
/// sizes at the literals headers' size classes, the 128 KiB block limit and
/// the parameter tables' 256 KiB class.
fn zstd_encoder_inputs() -> Array[(String, Bytes)] {
  let rng = @codec_harness.Rng::new(8878)
  let random = (n : Int32) => {
    Bytes::makei(n, _ => (rng.below(1 << 16) >> 8).to_byte())
  }
  let text = (n : Int32) => {
    let words = ["the ", "zstd ", "frame ", "window ", "of ", "a ", "\n"]
    let out = Buffer()
    while out.length() < n {
      out.write_string_utf8(words[rng.below(words.length())])
    }
    out.to_bytes()[:n].to_owned()
  }
  let inputs = [
    ("empty", b""),
    ("one byte", b"x"),
    ("run", Bytes::make(5000, b'a')),
    ("text", text(5000)),
    ("random", random(3000)),
    ("large", text(100000) + random(70000) + Bytes::make(40000, b'\x00')),
  ]
  for
    n in [
      31, 32, 1023, 1024, 4095, 4096, 16383, 16384, 131071, 131072, 131073, 262143,
      262144,
    ] {
    inputs.push(("text \{n}", text(n)))
  }
  inputs
}

///|
test "the zstd encoder keeps the byte-stream contract" {
  let decoder = () => @zstd.Decoder()
  for named in zstd_encoder_inputs() {
    let (name, input) = named
    let n = input.length()
    // Level, whether the content size is given, and the checksum.
    let configs = [
      (1, false, true),
      (1, true, true),
      (2, false, true),
      (2, true, false),
      (3, false, true),
      (3, true, true),
      (3, false, false),
      (4, false, true),
      (4, true, true),
      (5, false, true),
      (5, true, true),
      (6, false, true),
      (6, true, false),
      (7, true, true),
      (8, false, true),
      (8, true, true),
      (9, true, true),
      (10, true, true),
      (11, true, true),
      (12, false, true),
      (12, true, false),
    ]
    for config in configs {
      let (level, sized, checksum) = config
      let label = "zstd encoder level \{level} sized \{sized} checksum \{checksum} \{name}"
      let encoder = () => {
        if sized {
          @zstd.Encoder(level~, checksum~, content_size=n.to_int64())
        } else {
          @zstd.Encoder(level~, checksum~)
        }
      }
      let whole = @codec_harness.check_roundtrip(
        encoder,
        decoder,
        input,
        encoder_memory_limit=Some(zstd_encoder_memory),
        decoder_memory_limit=Some(zstd_memory(22)),
        small=20000,
      ) catch {
        e => fail("\{label}: \{e}")
      }
      if sized && whole != @zstd.compress(input, level~, checksum~) {
        fail("\{label}: compress writes another frame")
      }
      // Before any input, after one byte, twice at the same place, and
      // at the end.
      let flush_at = [0, n.min(1), n / 3, n / 3, n / 2, n]
      flush_at.sort()
      @codec_harness.check_flush(encoder, decoder, input, flush_at~) catch {
        e => fail("\{label} flush: \{e}")
      }
    }
  }
  let inputs = zstd_encoder_inputs()
  for checksum in [true, false] {
    let wrapped = () => {
      @codec_harness.ByteEncoder::new(@zstd.Encoder(checksum~))
    }
    @codec_harness.check_reset(wrapped, inputs[5].1, inputs[3].1) catch {
      e => fail("zstd encoder checksum \{checksum} reset: \{e}")
    }
  }
}
