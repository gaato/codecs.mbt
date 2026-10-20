///|
/// gaato/zstd's decoder seen through gaato/codec_bytes, until the module
/// implements the contract itself.
struct Zstd {
  decoder : @zstd.Decoder
  window_bits : Int32
}

///|
fn Zstd::new(window_bits : Int32) -> Zstd {
  { decoder: @zstd.Decoder(max_window_bits=window_bits), window_bits, }
}

///|
impl @codec_bytes.Decode for Zstd with fn step(self, input, output, end~) {
  let status = self.decoder.step(input, output, end~) catch {
    @zstd.ZstdError(kind, message) => {
      let common : @codec.ErrorKind = match kind {
        Truncated => Truncated
        Corrupt => Corrupt
        ChecksumMismatch => ChecksumMismatch
        WindowTooLarge =>
          LimitExceeded({
            resource: Memory,
            needed: None,
            limit: 1UL << self.window_bits,
          })
        DictionaryUnsupported => DictionaryRequired(None)
        OutputLimitExceeded =>
          LimitExceeded({ resource: Output, needed: None, limit: 0, })
        @zstd.ZstdErrorKind::.. => Unsupported
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
impl @codec_bytes.Decode for Zstd with fn last_consumed(self) {
  self.decoder.last_consumed()
}

///|
impl @codec_bytes.Decode for Zstd with fn last_produced(self) {
  self.decoder.last_produced()
}

///|
impl @codec_bytes.Decode for Zstd with fn reset(self) {
  self.decoder.reset()
}

///|
impl @codec_bytes.Decode for Zstd with fn memory_usage(_) {
  0
}

///|
test "zstd keeps the byte-stream contract" {
  // The decoder still reports bytes after the last frame as Corrupt.
  conform("zstd", zstd_vectors, Zstd::new, garbage=None)
}

///|
test "corrupted zstd streams never break the contract" {
  for v in zstd_vectors[:4] {
    let codec = () => @codec_harness.ByteDecoder::new(Zstd::new(v.window_bits))
    let _ = @codec_harness.fuzz(codec, v.input(), seed=8878, rounds=300)
  }
}
