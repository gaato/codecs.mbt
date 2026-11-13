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
  // A block is never larger than its input and its 3-byte header, and the
  // frame adds at most 18 header and 4 checksum bytes; one block more
  // allows for an empty last block.
  let n = input.length()
  let blocks = n / encoder.block_max.max(1) + 2
  let bound = n.to_int64() + 3L * blocks.to_int64() + 22L
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
      return if pos == out.length() {
        // The array is not used again.
        out.unsafe_reinterpret_as_bytes()
      } else {
        Bytes::from_array(out[:pos])
      }
    }
    // Only NeedMoreOutput comes before Done under Finish: the array is
    // full.
    let grown = FixedArray::make(out.length() * 2, b'\x00')
    FixedArray::unsafe_blit(grown, 0, out, 0, pos)
    out = grown
  }
}
