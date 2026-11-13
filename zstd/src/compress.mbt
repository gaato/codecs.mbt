///|
/// Compresses `input` into one whole Zstandard frame. `level` and
/// `checksum` are as for `Encoder`; the frame states its content size, and
/// the parameters are chosen for it, so a small input declares a small
/// window (a single-segment frame, whose window is its content).
pub fn compress(
  input : BytesView,
  level~ : Int32 = DEFAULT_LEVEL,
  checksum~ : Bool = true,
) -> Bytes {
  let encoder = Encoder(
    level~,
    checksum~,
    content_size=input.length().to_int64(),
  )
  let chunk = FixedArray::make(1 << 16, b'\x00')
  let out = Buffer()
  let mut rest = input
  for ;; {
    // The input is exactly the content size given, so the step never
    // raises.
    let status = try! encoder.step_into(rest, chunk, action=Finish)
    rest = rest[encoder.last_consumed():]
    out.write_bytesview(Bytes::from_array(chunk[:encoder.last_produced()])[:])
    if status is Done {
      return out.to_bytes()
    }
  }
}
