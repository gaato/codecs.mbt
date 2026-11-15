///|
/// A zstd decoder that accepts windows of up to `1 << window_bits` bytes.
fn zstd(window_bits : Int32) -> @zstd.Decoder {
  @zstd.Decoder(max_window_bits=window_bits)
}

///|
/// The bound gaato/zstd gives for a decoder's `memory_usage` at a window
/// limit.
fn zstd_memory(window_bits : Int32) -> Int32 {
  @zstd.decoder_memory_bound(max_window_bits=window_bits).to_int()
}

///|
test "zstd keeps the byte-stream contract" {
  // Four bytes that are neither a frame nor a skippable frame are trailing.
  // Every vector is a whole stream, so the next one begins another member.
  conform(
    "zstd",
    zstd_vectors,
    (window_bits, until) => @zstd.Decoder(max_window_bits=window_bits, until~),
    memory_limit=zstd_memory,
    // Several frames, or a skippable frame (a member of its own), make more
    // than one member.
    one_member=v => {
      !v.name.contains("two_frames") && !v.name.contains("skippable")
    },
    garbage=[
      b"\x00\x00\x00\x00\x00\x00\x00\x00", b"\xff\xff\xff\xff\xff\xff\xff\xff",
    ],
  )
}

///|
test "corrupted zstd streams never break the contract" {
  // Streams that hold data: corrupting an empty one tries little.
  let holding = zstd_vectors.filter(v => v.size > 0)
  for v in holding[:holding.length().min(8)] {
    let codec = () => @codec_harness.ByteDecoder::new(zstd(v.window_bits))
    let _ = @codec_harness.fuzz(
      codec,
      v.input(),
      seed=8878,
      rounds=300,
      memory_limit=Some(zstd_memory(v.window_bits)),
    )
  }
}
