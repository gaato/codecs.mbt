///|
/// Decodes a whole Brotli stream held in memory. `max_output` caps the
/// decoded size (unlimited by default) and raises `OutputLimitExceeded`
/// past it; `max_window_bits` is as for `Decoder`.
pub fn decompress(
  input : BytesView,
  max_output? : Int32,
  max_window_bits~ : Int32 = 24,
) -> Bytes raise BrotliError {
  let decoder = Decoder(max_window_bits~)
  let chunk = FixedArray::make(1 << 16, b'\x00')
  let out = Buffer()
  let mut rest = input
  for ;; {
    let status = decoder.step_into(rest, chunk, end=true)
    rest = rest[decoder.last_consumed():]
    let produced = decoder.last_produced()
    if max_output is Some(limit) && out.length() + produced > limit {
      raise BrotliError(
        OutputLimitExceeded,
        "the output exceeds \{limit} bytes",
      )
    }
    out.write_bytesview(Bytes::from_array(chunk[:produced])[:])
    if status is Done {
      return out.to_bytes()
    }
  }
}
