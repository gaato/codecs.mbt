///|
test "zstd decode" (b : @bench.T) {
  let text = decode64(zstd_text)
  let binary = decode64(zstd_binary)
  let out = FixedArray::make(1 << 16, b'\x00')
  assert_eq(@compare.zstd_steps(text, out), text_size)
  assert_eq(@compare.zstd_steps(binary, out), binary_size)
  // gaato/zstd as bench_test.mbt calls it: into 64 KiB slices.
  let benches : Array[(String, () -> Unit)] = [
    ("gaato/zstd steps text", () => b.keep(@compare.zstd_steps(text, out))),
    ("gaato/zstd steps binary", () => b.keep(@compare.zstd_steps(binary, out))),
  ]
  add_whole(benches, b, @compare.zstd_whole(), "text", text, text_size)
  add_whole(benches, b, @compare.zstd_whole(), "binary", binary, binary_size)
  run_all(b, benches)
}
