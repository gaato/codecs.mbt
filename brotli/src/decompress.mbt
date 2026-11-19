///|
/// Decodes a whole Brotli stream held in memory. `max_output` caps the
/// decoded size (unlimited by default) and raises
/// `LimitExceeded({ resource: Output, .. })` past it, with `max_output` (0
/// for a negative one) as the limit; `max_window_bits` and `dictionary` are
/// as for `Decoder`.
pub fn decompress(
  input : BytesView,
  max_output? : Int32,
  max_window_bits~ : Int32 = 24,
  dictionary? : Dictionary,
) -> Bytes raise @codec.CodecError {
  let decoder = Decoder(max_window_bits~, dictionary?)
  @whole.decode(input, max_output?, (rest, room) => {
    let status = decoder.step(rest, room, end=true)
    (decoder.last_consumed(), decoder.last_produced(), status is Done)
  })
}
