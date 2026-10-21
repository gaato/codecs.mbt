///|
/// Decodes a whole raw DEFLATE stream held in memory. `max_output` caps the
/// decoded size (unlimited by default) and raises
/// `LimitExceeded({ resource: Output, .. })` past it; bytes after the final
/// block raise `TrailingData`.
pub fn decompress(
  input : BytesView,
  max_output? : Int32,
) -> Bytes raise @codec.CodecError {
  let decoder = Decoder()
  let chunk = FixedArray::make(1 << 16, b'\x00')
  let out = Buffer()
  let mut rest = input
  for ;; {
    let status = decoder.step_into(rest, chunk, end=true)
    rest = rest[decoder.last_consumed():]
    let produced = decoder.last_produced()
    // `out` holds at most `limit` bytes, so this cannot overflow.
    if max_output is Some(limit) && produced > limit - out.length() {
      raise CodecError(
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
/// Compresses `input` into a whole raw DEFLATE stream, at `level` (0 to 9,
/// clamped; 6 by default) and with the preset `dictionary` if given, as
/// `Encoder` does.
pub fn compress(
  input : BytesView,
  level~ : Int32 = 6,
  dictionary? : BytesView,
) -> Bytes {
  let encoder = Encoder(level~, dictionary?)
  let chunk = FixedArray::make(1 << 16, b'\x00')
  let out = Buffer()
  let mut rest = input
  for ;; {
    let status = encoder.step_into(rest, chunk, action=Finish)
    rest = rest[encoder.last_consumed():]
    out.write_bytesview(Bytes::from_array(chunk[:encoder.last_produced()])[:])
    if status is Done {
      return out.to_bytes()
    }
  }
}
