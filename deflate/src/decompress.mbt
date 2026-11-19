///|
/// Decodes a whole raw DEFLATE stream held in memory, with the preset
/// `dictionary` if the stream was compressed with one, as `Decoder` does.
/// `max_output` caps the decoded size (unlimited by default; 0 for a
/// negative one) and raises `LimitExceeded({ resource: Output, .. })` past
/// it; bytes after the final block raise `TrailingData`.
pub fn decompress(
  input : BytesView,
  dictionary? : BytesView,
  max_output? : Int32,
) -> Bytes raise @codec.CodecError {
  let decoder = Decoder(dictionary?)
  @whole.decode(input, max_output?, (rest, room) => {
    let status = decoder.step(rest, room, end=true)
    (decoder.last_consumed(), decoder.last_produced(), status is Done)
  })
}

///|
/// Compresses `input` into a whole raw DEFLATE stream, at `level` (0 to 9,
/// clamped, with -1 as 6; 6 by default), with the preset `dictionary` if
/// given and a window of `1 << window_bits` bytes, as `Encoder` does.
pub fn compress(
  input : BytesView,
  level~ : Int32 = 6,
  dictionary? : BytesView,
  window_bits~ : Int32 = 15,
) -> Bytes {
  let encoder = Encoder(level~, dictionary?, window_bits~)
  @whole.encode(input, (rest, room) => {
    let status = encoder.step(rest, room, action=Finish)
    (encoder.last_consumed(), encoder.last_produced(), status is Done)
  })
}
