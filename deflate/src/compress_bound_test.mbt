///|
/// Bytes from a seeded LCG: input that does not compress.
fn incompressible(n : Int32, seed : UInt64) -> Bytes {
  let mut state = seed
  Bytes::makei(n, _ => {
    state = state * 6364136223846793005UL + 1442695040888963407UL
    (state >> 56).to_byte()
  })
}

///|
/// The bound RESOURCE_BOUNDS.md gives for raw DEFLATE: the input, 5 bytes
/// for each stored block of up to 65,535 of it (one for empty input), and a
/// byte of padding.
fn raw_bound(n : Int32) -> Int32 {
  n + 5 * ((n + 65534) / 65535).max(1) + 1
}

///|
test "a whole stream is never larger than storing its input" {
  for n in [0, 1, 1000, 65535, 65536, 131070, 131071, 300000] {
    let input = incompressible(n, n.to_uint64() + 1)
    for level in -1..<=9 {
      for window_bits in [8, 15] {
        let raw = @deflate.compress(input, level~, window_bits~)
        assert_true(raw.length() <= raw_bound(n), msg="raw \{n} \{level}")
        assert_true(@deflate.decompress(raw) == input)
        // zlib adds its 2-byte header and 4-byte Adler-32.
        let zlib = @zlib.compress(input, level~, window_bits~)
        assert_true(zlib.length() <= raw_bound(n) + 6, msg="zlib \{n} \{level}")
      }
      // gzip adds a 10-byte header and an 8-byte trailer.
      let gzip = @gzip.compress(input, level~)
      assert_true(gzip.length() <= raw_bound(n) + 18, msg="gzip \{n} \{level}")
    }
  }
}
