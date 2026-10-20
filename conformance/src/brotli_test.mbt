///|
/// gaato/brotli's decoder seen through gaato/codec_bytes, until the module
/// implements the contract itself.
struct Brotli {
  decoder : @brotli.Decoder
  window_bits : Int32
}

///|
fn Brotli::new(window_bits : Int32) -> Brotli {
  { decoder: @brotli.Decoder(max_window_bits=window_bits), window_bits, }
}

///|
impl @codec_bytes.Decode for Brotli with fn step(self, input, output, end~) {
  let status = self.decoder.step(input, output, end~) catch {
    @brotli.BrotliError(kind, message) => {
      let common : @codec.ErrorKind = match kind {
        Truncated => Truncated
        Corrupt => Corrupt
        TrailingData => TrailingData
        WindowTooLarge =>
          LimitExceeded({
            resource: Memory,
            needed: None,
            limit: 1UL << self.window_bits,
          })
        OutputLimitExceeded =>
          LimitExceeded({ resource: Output, needed: None, limit: 0, })
        @brotli.BrotliErrorKind::.. => Unsupported
      }
      raise @codec.CodecError(common, message)
    }
  }
  match status {
    Done => Done
    NeedMoreInput => NeedMoreInput
    NeedMoreOutput => NeedMoreOutput
  }
}

///|
impl @codec_bytes.Decode for Brotli with fn last_consumed(self) {
  self.decoder.last_consumed()
}

///|
impl @codec_bytes.Decode for Brotli with fn last_produced(self) {
  self.decoder.last_produced()
}

///|
impl @codec_bytes.Decode for Brotli with fn reset(self) {
  self.decoder.reset()
}

///|
impl @codec_bytes.Decode for Brotli with fn memory_usage(_) {
  0
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
test "corrupted brotli streams never break the contract" {
  for v in brotli_vectors[:8] {
    let codec = () => @codec_harness.ByteDecoder::new(Brotli::new(24))
    let _ = @codec_harness.fuzz(codec, v.input(), seed=7932, rounds=200)
  }
}
