///|
/// Decodes a whole gzip stream held in memory: every member, each checked
/// against its CRC-32 and length, their data concatenated. `max_output` caps
/// the decoded size (unlimited by default) and raises
/// `LimitExceeded({ resource: Output, .. })` past it; bytes after the last
/// member that begin no member raise `TrailingData`.
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
