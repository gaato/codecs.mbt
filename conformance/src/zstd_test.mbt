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
  conform(
    "zstd",
    zstd_vectors,
    zstd,
    garbage=Some([
      b"\x00\x00\x00\x00\x00\x00\x00\x00", b"\xff\xff\xff\xff\xff\xff\xff\xff",
    ]),
  )
}

///|
test "zstd stays within its documented memory" {
  for v in zstd_vectors {
    let codec = () => @codec_harness.ByteDecoder::new(zstd(v.window_bits))
    let _ = @codec_harness.check_splits(
      codec,
      v.input(),
      memory_limit=Some(zstd_memory(v.window_bits)),
    ) catch {
      e => fail("zstd \{v.name}: \{e}")
    }
  }
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

///|
/// Steps `decoder` over `input` in chunks of `input_sizes` into room of
/// `output_sizes` until `Done`, and returns the output and how many input
/// bytes were consumed. `end` is set once the last chunk is handed over.
fn[D : @codec_bytes.Decode] until_done(
  decoder : D,
  input : BytesView,
  input_sizes : @codec_harness.Sizes,
  output_sizes : @codec_harness.Sizes,
) -> (Bytes, Int32) raise {
  let output = Buffer()
  let mut taken = 0
  let mut pos = 0
  for ;; {
    if taken == pos && pos < input.length() {
      pos = (pos + (input_sizes.next)()).min(input.length())
    }
    let out = FixedArray::make((output_sizes.next)(), b'\x00')
    let status = decoder.step(
      input[taken:pos],
      out.mut_view(),
      end=pos == input.length(),
    )
    taken += decoder.last_consumed()
    output.write_bytes(Bytes::from_array(out[:decoder.last_produced()]))
    match status {
      Done => return (output.to_bytes(), taken)
      NeedMoreInput => if taken != pos { fail("NeedMoreInput with input left") }
      NeedMoreOutput => ()
    }
  }
}

///|
test "zstd until=EndOfMember stops after the first of two streams" {
  // Vectors of one frame each, followed by the next vector.
  let single = zstd_vectors.filter(v => {
    !v.name.contains("two_frames") && !v.name.contains("skippable")
  })
  for i in 0..<(single.length() - 1) {
    let first = single[i]
    let second = single[i + 1]
    let input = Bytes::from_array([..first.input()[:], ..second.input()[:]])
    let seed = i.reinterpret_as_uint()
    let (output, taken) = until_done(
      @zstd.Decoder(max_window_bits=first.window_bits, until=EndOfMember),
      input,
      @codec_harness.Sizes::random(seed, 1500),
      @codec_harness.Sizes::random(seed + 1, 5000),
    )
    if output.length() != first.size ||
      @codec_harness.sha256(output) != first.sha256 {
      fail("zstd \{first.name}: the first stream does not decode")
    }
    // What is left is exactly the second stream, and decodes as one.
    let rest = input[taken:]
    if rest != second.input()[:] {
      fail("zstd \{first.name}: \{taken} bytes consumed, not the first stream")
    }
    let codec = () => @codec_harness.ByteDecoder::new(zstd(second.window_bits))
    let run = @codec_harness.drive(codec(), rest)
    if run.error is Some(_) ||
      @codec_harness.sha256(run.output) != second.sha256 {
      fail("zstd \{second.name}: the rest does not decode")
    }
  }
}
