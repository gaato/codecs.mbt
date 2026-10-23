///|
test "brotli decode" (b : @bench.T) {
  let text = decode64(brotli_text)
  let binary = decode64(brotli_binary)
  let out = FixedArray::make(1 << 16, b'\x00')
  assert_eq(@compare.brotli_steps(text, out), text_size)
  assert_eq(@compare.brotli_steps(binary, out), binary_size)
  let benches : Array[(String, () -> Unit)] = [
    ("gaato/brotli steps text", () => b.keep(@compare.brotli_steps(text, out))),
    (
      "gaato/brotli steps binary",
      () => b.keep(@compare.brotli_steps(binary, out)),
    ),
  ]
  add_whole(benches, b, @compare.brotli_whole(), "text", text, text_size)
  add_whole(benches, b, @compare.brotli_whole(), "binary", binary, binary_size)
  run_all(b, benches)
}

///|
test "brotli encode" (b : @bench.T) {
  let text = @brotli.decompress(decode64(brotli_text))
  let binary = @brotli.decompress(decode64(brotli_binary))
  let benches : Array[(String, () -> Unit)] = []
  add_encode(benches, b, @compare.brotli_compress(), "text", text)
  add_encode(benches, b, @compare.brotli_compress(), "binary", binary)
  run_all(b, benches)
}
