///|
test "deflate decode" (b : @bench.T) {
  let text = gzip_body(decode64(gzip_text))
  let binary = gzip_body(decode64(gzip_binary))
  let out = FixedArray::make(1 << 16, b'\x00')
  assert_eq(@compare.deflate_steps(text, out), text_size)
  assert_eq(@compare.flate_steps(text, out), text_size)
  // moonbit-community/flate's streaming decoder, called as gaato/deflate's.
  let benches : Array[(String, () -> Unit)] = [
    (
      "gaato/deflate steps text",
      () => b.keep(@compare.deflate_steps(text, out)),
    ),
    (
      "gaato/deflate steps binary",
      () => b.keep(@compare.deflate_steps(binary, out)),
    ),
    (
      "moonbit-community/flate 0.10.0 steps text",
      () => b.keep(@compare.flate_steps(text, out)),
    ),
    (
      "moonbit-community/flate 0.10.0 steps binary",
      () => b.keep(@compare.flate_steps(binary, out)),
    ),
  ]
  add_whole(benches, b, @compare.deflate_whole(), "text", text, text_size)
  add_whole(benches, b, @compare.deflate_whole(), "binary", binary, binary_size)
  run_all(b, benches)
}

///|
test "deflate encode" (b : @bench.T) {
  let text = @deflate.decompress(gzip_body(decode64(gzip_text)))
  let binary = @deflate.decompress(gzip_body(decode64(gzip_binary)))
  let benches : Array[(String, () -> Unit)] = []
  add_encode(benches, b, @compare.deflate_compress(), "text", text)
  add_encode(benches, b, @compare.deflate_compress(), "binary", binary)
  run_all(b, benches)
}
