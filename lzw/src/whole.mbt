// Whole inputs at once, the bounds callers size buffers by, and the
// gaato/codec_bytes traits.

///|
/// Compresses `input` into a whole stream of `format`, as `Encoder` writes
/// it. Raises `Unsupported` for a byte a GIF minimum code size under 8
/// cannot code.
pub fn compress(
  input : BytesView,
  format : Format,
) -> Bytes raise @codec.CodecError {
  let encoder = Encoder(format)
  let chunk = FixedArray::make(1 << 16, b'\x00')
  let out = Buffer()
  let mut rest = input
  for ;; {
    let status = encoder.step(rest, chunk.mut_view(), action=Finish)
    rest = rest[encoder.last_consumed():]
    out.write_bytesview(Bytes::from_array(chunk[:encoder.last_produced()])[:])
    if status is Done {
      return out.to_bytes()
    }
  }
}

///|
/// Decodes a whole stream of `format`, as `Decoder` reads it.
/// `max_output` caps the decoded size (unlimited by default) and raises
/// `LimitExceeded({ resource: Output, .. })` past it, with `max_output` (0
/// for a negative one) as the limit.
pub fn decompress(
  input : BytesView,
  format : Format,
  max_output? : Int32,
  allow_missing_end~ : Bool = false,
) -> Bytes raise @codec.CodecError {
  let decoder = Decoder(format, allow_missing_end~)
  let chunk = FixedArray::make(1 << 16, b'\x00')
  let out = Buffer()
  let mut rest = input
  for ;; {
    let status = decoder.step(rest, chunk.mut_view(), end=true)
    rest = rest[decoder.last_consumed():]
    let produced = decoder.last_produced()
    // `out` holds at most `limit` bytes, so this cannot overflow.
    if max_output is Some(limit) && produced > limit.max(0) - out.length() {
      raise @codec.CodecError(
        LimitExceeded({
          resource: Output,
          needed: None,
          limit: limit.max(0).to_uint64(),
        }),
        "the output exceeds \{limit} bytes",
      )
    }
    out.write_bytesview(Bytes::from_array(chunk[:produced])[:])
    if status is Done {
      return out.to_bytes()
    }
  }
}

///|
/// The most bytes `compress` or an `Encoder` writes for `n` bytes of input
/// in `format`: every byte a code of the widest width, with the clear and
/// end codes, a clear for every 3,000 bytes (no table is cleared sooner: a
/// GIF or TIFF table after some 3,800 codes, a .Z one after 10,000 bytes)
/// and, for .Z, the header and up to seven codes of padding at each of its
/// eight widths after each clear. A negative `n` counts as 0; past 2^56 the
/// result is the largest Int64.
pub fn compress_bound(n : Int64, format : Format) -> Int64 {
  let n = n.max(0L)
  guard n <= 0xFFFFFFFFFFFFFFL else { return 0x7FFFFFFFFFFFFFFFL }
  let clears = n / 3000L + 1L
  let padding = if format.unix { (clears + 1L) * 8L * 7L } else { 0L }
  let codes = n + 2L + clears + padding
  3L + (codes * format.max_bits.to_int64() + 7L) / 8L
}

///|
/// The most `Decoder::memory_usage` reports for `format`: 7 bytes a code
/// and one, 28,673 for GIF, TIFF and PDF, 458,753 for .Z of 16 bits.
pub fn decoder_memory_bound(format : Format) -> Int64 {
  (7L << format.max_bits) + 1L
}

///|
/// What `Encoder::memory_usage` reports for `format`, the same from the
/// first step to the last: 12 bytes a code and 256, 49,408 for GIF, TIFF
/// and PDF, 786,688 for .Z of 16 bits.
pub fn encoder_memory_bound(format : Format) -> Int64 {
  (12L << format.max_bits) + 256L
}

///|
/// Decodes through `Decoder::step`.
pub impl @codec_bytes.Decode for Decoder with fn step(self, input, output, end~) {
  Decoder::step(self, input, output, end~)
}

///|
/// Same as `Decoder::last_consumed`.
pub impl @codec_bytes.Decode for Decoder with fn last_consumed(self) {
  Decoder::last_consumed(self)
}

///|
/// Same as `Decoder::last_produced`.
pub impl @codec_bytes.Decode for Decoder with fn last_produced(self) {
  Decoder::last_produced(self)
}

///|
/// Same as `Decoder::reset`.
pub impl @codec_bytes.Decode for Decoder with fn reset(self) {
  Decoder::reset(self)
}

///|
/// Same as `Decoder::memory_usage`.
pub impl @codec_bytes.Decode for Decoder with fn memory_usage(self) {
  Decoder::memory_usage(self)
}

///|
/// Encodes through `Encoder::step`.
pub impl @codec_bytes.Encode for Encoder with fn step(
  self,
  input,
  output,
  action~,
) {
  Encoder::step(self, input, output, action~)
}

///|
/// Same as `Encoder::last_consumed`.
pub impl @codec_bytes.Encode for Encoder with fn last_consumed(self) {
  Encoder::last_consumed(self)
}

///|
/// Same as `Encoder::last_produced`.
pub impl @codec_bytes.Encode for Encoder with fn last_produced(self) {
  Encoder::last_produced(self)
}

///|
/// Same as `Encoder::reset`.
pub impl @codec_bytes.Encode for Encoder with fn reset(self) {
  Encoder::reset(self)
}

///|
/// Same as `Encoder::memory_usage`.
pub impl @codec_bytes.Encode for Encoder with fn memory_usage(self) {
  Encoder::memory_usage(self)
}
