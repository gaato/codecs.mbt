// Whole inputs at once, the bounds callers size buffers by, and the
// gaato/codec_bytes traits.

///|
/// Compresses `input` into a whole frame, as `Encoder` with the same options
/// writes it.
pub fn compress(
  input : BytesView,
  acceleration~ : Int32 = 1,
  block_size~ : BlockSize = Max64KiB,
  linked~ : Bool = true,
  checksum~ : Bool = true,
  block_checksum~ : Bool = false,
  dictionary? : BytesView,
  dictionary_id? : UInt32,
) -> Bytes {
  let encoder = Encoder(
    acceleration~,
    block_size~,
    linked~,
    checksum~,
    block_checksum~,
    dictionary?,
    dictionary_id?,
  )
  @whole.encode(input, (rest, room) => {
    // Without a content size, the encoder never raises.
    let status = encoder.step(rest, room, action=Finish) catch {
      _ => abort("compress: the encoder raised without a content size")
    }
    (encoder.last_consumed(), encoder.last_produced(), status is Done)
  })
}

///|
/// Decodes a whole stream: frames, skippable frames and legacy frames one
/// after another, as `Decoder` reads them. `max_output` caps the decoded
/// size (unlimited by default) and raises `LimitExceeded({ resource: Output,
/// .. })` past it, with `max_output` (0 for a negative one) as the limit.
pub fn decompress(
  input : BytesView,
  max_output? : Int32,
  dictionary? : BytesView,
) -> Bytes raise @codec.CodecError {
  let decoder = Decoder(dictionary?)
  @whole.decode(input, max_output?, (rest, room) => {
    let status = decoder.step(rest, room, end=true)
    (decoder.last_consumed(), decoder.last_produced(), status is Done)
  })
}

///|
/// Decodes one LZ4 block, all of `input`, as `LZ4_decompress_safe` does:
/// `max_output` is what the caller knows of its decoded size (lz4's
/// `dstCapacity`), and a block that decodes to more raises
/// `LimitExceeded({ resource: Output, .. })`. With `dictionary`, matches may
/// reach into its last 64 KiB (`LZ4_decompress_safe_usingDict`). A block
/// must end with literals, as the format has it; one that does not raises
/// `Corrupt`.
pub fn decompress_block(
  input : BytesView,
  max_output~ : Int32,
  dictionary? : BytesView,
) -> Bytes raise @codec.CodecError {
  let decoder = Decoder::make(EndOfInput, dictionary, true)
  decoder.block_max = max_output.max(0)
  @whole.decode(input, (rest, room) => {
    let status = decoder.step(rest, room, end=true)
    (decoder.last_consumed(), decoder.last_produced(), status is Done)
  })
}

///|
/// A skippable frame of `variant` (its low four bits are used) holding
/// `data`: the magic number `0x184D2A50 + variant`, the length of `data` in
/// four little-endian bytes, then `data`. Decoders skip it, so it carries
/// bytes of the caller's beside LZ4 frames.
pub fn skippable_frame(variant : Int32, data : BytesView) -> Bytes {
  let out = Writer::new(8 + data.length())
  out.le32(0x184D2A50U | (variant & 15).reinterpret_as_uint())
  out.le32(data.length().reinterpret_as_uint())
  out.data.blit_from_bytesview(8, data)
  Bytes::from_array(out.data[:])
}

///|
/// The most bytes `compress` or an `Encoder` writes for `n` bytes of input
/// in blocks of `block_size`: the header (19 bytes at most), each block's
/// bytes with its size and checksum (a block is stored uncompressed rather
/// than grow), the end mark and the content checksum. Each `Flush` adds a
/// block's 8. A negative `n` counts as 0; past 2^62 the result is the
/// largest Int64.
pub fn compress_bound(n : Int64, block_size~ : BlockSize = Max64KiB) -> Int64 {
  let n = n.max(0L)
  guard n <= 0x3FFFFFFFFFFFFFFFL else { return 0x7FFFFFFFFFFFFFFFL }
  let bs = block_size.bytes().to_int64()
  19L + n + 8L * ((n + bs - 1L) / bs) + 8L
}

///|
/// The most `Decoder::memory_usage` reports: its window, 256 KiB.
pub fn decoder_memory_bound() -> Int64 {
  WINDOW.to_int64()
}

///|
/// What `Encoder::memory_usage` reports at most for `block_size`, the same
/// from the first step to the last: the block and 64 KiB of history, two
/// hash tables of 2^13 entries, and a block's output with the header and
/// footer.
pub fn encoder_memory_bound(block_size~ : BlockSize = Max64KiB) -> Int64 {
  let bs = block_size.bytes()
  (HISTORY + bs + 4 * 2 * TABLE_ENTRIES + frame_overhead() + bs).to_int64()
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
