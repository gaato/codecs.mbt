///|
/// Decodes a whole Deflate64 stream (ZIP method 9), as `Decoder` does.
/// `max_output` caps the decoded size (unlimited by default; 0 for a
/// negative one) and raises `LimitExceeded({ resource: Output, .. })` past
/// it; bytes after the final block raise `TrailingData`.
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
