///|
/// A zstd decoder that accepts windows of up to `1 << window_bits` bytes.
fn zstd(window_bits : Int32) -> @zstd.Decoder {
  @zstd.Decoder(max_window_bits=window_bits)
}

///|
/// The most memory gaato/zstd documents for a window limit: the window and
/// two 128 KiB block buffers.
fn zstd_memory(window_bits : Int32) -> Int32 {
  (1 << window_bits) + 2 * (1 << 17)
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
  for v in zstd_vectors[:4] {
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
