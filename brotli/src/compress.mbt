///|
/// Compresses `input` into a whole Brotli stream. `window_bits` is as for
/// `Encoder`. At quality 4 the window declared is reduced to what the input
/// needs (at least 64 KiB), preserving its default output. Qualities 5..11
/// keep the requested window and pass the input length as `size_hint`, so
/// an `Encoder` given that hint and window produces the same stream.
/// `quality` and `dictionary` are as for `Encoder`.
pub fn compress(
  input : BytesView,
  quality~ : Int32 = 4,
  window_bits~ : Int32 = 22,
  dictionary? : Dictionary,
) -> Bytes {
  let mut wbits = window_bits.clamp(min=10, max=24)
  let reference = quality.clamp(min=0, max=11) > 4
  while !reference && wbits > 16 && (1 << (wbits - 1)) - 16 >= input.length() {
    wbits -= 1
  }
  let encoder = if reference {
    Encoder(
      quality~,
      size_hint=input.length().to_int64(),
      window_bits=wbits,
      dictionary?,
    )
  } else {
    Encoder(window_bits=wbits, dictionary?)
  }
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
