///|
/// Compresses `input` into a whole Brotli stream. `window_bits` is as for
/// `Encoder`; the window declared is no larger than `input` needs (and at
/// least 64 KiB), so that decoders reserve no more memory than necessary.
pub fn compress(input : BytesView, window_bits~ : Int32 = 22) -> Bytes {
  let mut wbits = window_bits.clamp(min=10, max=24)
  while wbits > 16 && (1 << (wbits - 1)) - 16 >= input.length() {
    wbits -= 1
  }
  let encoder = Encoder(window_bits=wbits)
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
