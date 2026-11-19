///|
/// Compresses `input` into a whole framed stream, as `Encoder` writes it.
/// Inputs over 2,147,221,517 bytes abort: the output is allocated at its
/// bound first, and theirs passes 2^31 - 1 bytes, the most an array holds;
/// an `Encoder` streams them.
pub fn compress(input : BytesView) -> Bytes {
  let encoder = Encoder()
  let bound = compress_bound(input.length().to_int64())
  guard bound <= 0x7FFFFFFFL else {
    abort(
      "compress: \{input.length()} bytes, whose bound passes 2^31 - 1 bytes",
    )
  }
  let out = FixedArray::make(bound.to_int(), b'\x00')
  let status = encoder.step(input, out.mut_view(), action=Finish)
  guard status is Done else { abort("compress: the bound was too small") }
  @whole.take(out, encoder.last_produced())
}

///|
/// Decodes a whole framed stream. `max_output` caps the decoded size
/// (unlimited by default) and raises `LimitExceeded({ resource: Output, .. })`
/// past it, with `max_output` (0 for a negative one) as the limit.
pub fn decompress(
  input : BytesView,
  max_output? : Int32,
) -> Bytes raise @codec.CodecError {
  let decoder = Decoder()
  @whole.decode(input, max_output?, (rest, room) => {
    let status = decoder.step(rest, room, end=true)
    (decoder.last_consumed(), decoder.last_produced(), status is Done)
  })
}

///|
/// The most bytes `compress` or an `Encoder` writes for `n` bytes of input:
/// the 10-byte stream identifier, and for each chunk of up to 64 KiB its
/// bytes and 8 more (a chunk is stored uncompressed rather than grow). Each
/// `Flush` adds a chunk's 8. A negative `n` counts as 0; past 2^62 the
/// result is the largest Int64.
pub fn compress_bound(n : Int64) -> Int64 {
  let n = n.max(0L)
  guard n <= 0x3FFFFFFFFFFFFFFFL else { return 0x7FFFFFFFFFFFFFFFL }
  10L + n + 8L * ((n + BLOCK_SIZE.to_int64() - 1L) / BLOCK_SIZE.to_int64())
}

///|
/// The most `Decoder::memory_usage` reports: the 4-byte chunk header, a
/// chunk's body (76,494 bytes) and its decoded bytes (65,536).
pub fn decoder_memory_bound() -> Int64 {
  (4 + MAX_COMPRESSED_BODY + BLOCK_SIZE).to_int64()
}

///|
/// What `Encoder::memory_usage` reports, the same from the first step to
/// the last.
pub fn encoder_memory_bound() -> Int64 {
  ENCODER_MEMORY.to_int64()
}

///|
/// An encoder's buffers: 64 KiB of input, a chunk's output with the stream
/// identifier, the raw stream it is made from, and the 2^14-entry table.
const ENCODER_MEMORY : Int32 = BLOCK_SIZE +
  (10 + 8 + 32 + BLOCK_SIZE + BLOCK_SIZE / 6) +
  (32 + BLOCK_SIZE + BLOCK_SIZE / 6) +
  2 * (1 << MAX_HASH_BITS)

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
/// Encodes through `Encoder::step`; the encoder never raises.
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
