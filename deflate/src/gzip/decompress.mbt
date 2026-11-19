///|
/// Decodes a whole gzip stream held in memory: every member, each checked
/// against its CRC-32 and length, their data concatenated. `max_output` caps
/// the decoded size (unlimited by default; 0 for a negative one) and raises
/// `LimitExceeded({ resource: Output, .. })` past it; bytes after the last
/// member that begin no member raise `TrailingData`. Headers are skipped
/// (`keep_header=false`): their extra fields, names and comments are not
/// kept, so a header of any size decodes, and its CRC is still checked.
pub fn decompress(
  input : BytesView,
  max_output? : Int32,
) -> Bytes raise @codec.CodecError {
  let decoder = Decoder(keep_header=false)
  @whole.decode(input, max_output?, (rest, room) => {
    let status = decoder.step(rest, room, end=true)
    (decoder.last_consumed(), decoder.last_produced(), status is Done)
  })
}

///|
/// Compresses `input` into a whole gzip stream of one member, at `level` (0
/// to 9, clamped, with -1 as 6; 6 by default) and with `header` if given, as `Encoder`
/// does: a header that is not writable (`Header::is_writable`) aborts.
pub fn compress(
  input : BytesView,
  level~ : Int32 = 6,
  header? : Header,
) -> Bytes {
  let encoder = Encoder(level~, header?)
  @whole.encode(input, (rest, room) => {
    let status = encoder.step(rest, room, action=Finish)
    (encoder.last_consumed(), encoder.last_produced(), status is Done)
  })
}
