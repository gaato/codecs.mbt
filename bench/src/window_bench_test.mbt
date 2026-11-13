///|
test "zstd large window" (b : @bench.T) {
  let text = try! @zstd.decompress(decode64(zstd_text))
  // Twenty-four copies, with a varying byte every 257 positions. This is
  // 12 MiB, beyond twice the largest (4 MiB) encoder window.
  let input = Bytes::makei(24 * text.length(), i => {
    if i % 257 == 0 {
      (text[i % text.length()].to_int() ^ (i / text.length())).to_byte()
    } else {
      text[i % text.length()]
    }
  })
  for level in [1, 3, 12] {
    b.bench(name="zstd encode varied text 12 MiB level \{level}", () => {
      b.keep(zstd_encode(input, level))
    })
  }
}
