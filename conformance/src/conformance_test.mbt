///|
/// The checks of the contract, over every vector of a format.
fn[D : @codec_bytes.Decode] conform(
  label : String,
  vectors : Array[Vector],
  make : (Int32) -> D,
  garbage~ : Array[Bytes]?,
) -> Unit raise {
  for v in vectors {
    let input = v.input()
    let codec = () => @codec_harness.ByteDecoder::new(make(v.window_bits))
    let whole = @codec_harness.check_splits(codec, input) catch {
      e => fail("\{label} \{v.name}: \{e}")
    }
    if whole.error is Some(_) ||
      whole.output.length() != v.size ||
      @codec_harness.sha256(whole.output) != v.sha256 {
      fail("\{label} \{v.name}: does not decode to its original")
    }
    @codec_harness.check_truncation(codec, input, whole, max_prefixes=64) catch {
      e => fail("\{label} \{v.name}: \{e}")
    }
    if garbage is Some(garbage) {
      @codec_harness.check_trailing(codec, input, garbage~) catch {
        e => fail("\{label} \{v.name}: \{e}")
      }
    }
  }
  let first = vectors[0].input()
  let last = vectors[vectors.length() - 1].input()
  let wide = () => @codec_harness.ByteDecoder::new(make(24))
  @codec_harness.check_reset(wide, last, first) catch {
    e => fail("\{label} reset: \{e}")
  }
}

///|
test "zstd keeps the byte-stream contract" {
  // The decoder still reports bytes after the last frame as Corrupt.
  conform("zstd", zstd_vectors, Zstd::new, garbage=None)
}

///|
test "brotli keeps the byte-stream contract" {
  // Brotli has no framing: any byte after the stream is trailing.
  conform(
    "brotli",
    brotli_vectors,
    Brotli::new,
    garbage=Some([b"\x00", b"\xff\xff\xff\xff\xff\xff\xff\xff"]),
  )
}

///|
test "corrupted zstd streams never break the contract" {
  for v in zstd_vectors[:4] {
    let codec = () => @codec_harness.ByteDecoder::new(Zstd::new(v.window_bits))
    let _ = @codec_harness.fuzz(codec, v.input(), seed=8878, rounds=300)
  }
}

///|
test "corrupted brotli streams never break the contract" {
  for v in brotli_vectors[:8] {
    let codec = () => @codec_harness.ByteDecoder::new(Brotli::new(24))
    let _ = @codec_harness.fuzz(codec, v.input(), seed=7932, rounds=200)
  }
}
