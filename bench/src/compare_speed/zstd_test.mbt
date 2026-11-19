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
  // moonbitstack/moonzip 0.4.1 refuses both streams: it computes the
  // content checksum `zstd -3` writes differently ("checksum ... does not
  // match"), as it does for 15 of the 36 valid streams of compare_check.
  let decoders = @compare.zstd_whole().filter(d => {
    !d.name.has_prefix("moonbitstack/moonzip")
  })
  add_whole(benches, b, decoders, "text", text, text_size)
  add_whole(benches, b, decoders, "binary", binary, binary_size)
  run_all(b, benches)
}

///|
test "zstd encode" (b : @bench.T) {
  let text = @zstd.decompress(decode64(zstd_text))
  let binary = @zstd.decompress(decode64(zstd_binary))
  let benches : Array[(String, () -> Unit)] = []
  add_encode(benches, b, @compare.zstd_compress(), "text", text)
  add_encode(benches, b, @compare.zstd_compress(), "binary", binary)
  run_all(b, benches)
}
