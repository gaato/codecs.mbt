///|
/// Compresses `input` into one whole Zstandard frame. `level`, `checksum`
/// and `dictionary` are as for `Encoder`; the frame states its content size, and
/// the parameters are chosen for it, so a small input declares a small
/// window (a single-segment frame, whose window is its content).
pub fn compress(
  input : BytesView,
  level~ : Int32 = DEFAULT_LEVEL,
  checksum~ : Bool = true,
  dictionary? : Dictionary,
) -> Bytes {
  let encoder = Encoder(
    level~,
    checksum~,
    content_size=input.length().to_int64(),
    dictionary?,
  )
  let bound = compress_bound(input.length().to_int64())
  encode_whole(encoder, input, bound.min(0x7fffffffL).to_int())
}

///|
/// Encodes all of `input` with `Finish` into one array of `capacity`
/// bytes, grown if the frame does not fit, and trims it with one copy.
fn encode_whole(
  encoder : Encoder,
  input : BytesView,
  capacity : Int32,
) -> Bytes {
  let mut out = FixedArray::make(capacity.max(1), b'\x00')
  let mut pos = 0
  let mut rest = input
  for ;; {
    // The input is exactly the content size given, so the step never
    // raises.
    let status = try! encoder.step(rest, out.mut_view(start=pos), action=Finish)
    rest = rest[encoder.last_consumed():]
    pos += encoder.last_produced()
    if status is Done {
      return @whole.take(out, pos)
    }
    // Only NeedMoreOutput comes before Done under Finish: the array is
    // full.
    let grown = FixedArray::make(out.length() * 2, b'\x00')
    @blit.bytes(grown, 0, out, 0, pos)
    out = grown
  }
}
