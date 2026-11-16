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
test "a whole stream is never larger than storing its input" {
  for n in [0, 1, 1000, 65535, 65536, 131070, 131071, 300000] {
    let input = incompressible(n, n.to_uint64() + 1)
    for level in -1..<=12 {
      for window_bits in [8, 15] {
        let raw = @deflate.compress(input, level~, window_bits~)
        assert_true(
          raw.length().to_int64() <= @deflate.compress_bound(n.to_int64()),
          msg="raw \{n} \{level}",
        )
        assert_true(@deflate.decompress(raw) == input)
        // zlib adds its 2-byte header and 4-byte Adler-32.
        let zlib = @zlib.compress(input, level~, window_bits~)
        assert_true(
          zlib.length().to_int64() <= @zlib.compress_bound(n.to_int64()),
          msg="zlib \{n} \{level}",
        )
      }
      // gzip adds a 10-byte header and an 8-byte trailer.
      let gzip = @gzip.compress(input, level~)
      assert_true(
        gzip.length().to_int64() <= @gzip.compress_bound(n.to_int64()),
        msg="gzip \{n} \{level}",
      )
    }
  }
}

///|
test "gzip's bound counts the header's fields" {
  let header : @gzip.Header = {
    text: false,
    mtime: 0,
    xfl: b'\x00',
    os: b'\xff',
    extra: Some(b"extra field"),
    name: Some(b"name.txt"),
    comment: Some(b"a comment"),
  }
  for n in [0, 1000, 70000] {
    let input = incompressible(n, 7)
    let stream = @gzip.compress(input, header~)
    assert_true(
      stream.length().to_int64() <= @gzip.compress_bound(n.to_int64(), header~),
    )
  }
  // The header's 10 bytes, 2 + 11, 8 + 1 and 9 + 1.
  assert_eq(
    @gzip.encoder_memory_bound(header~).to_int(),
    @deflate.encoder_memory_bound().to_int() + 42,
  )
  assert_eq(
    @gzip.Encoder(header~).memory_usage(),
    @gzip.encoder_memory_bound(header~).to_int(),
  )
}

///|
test "the memory bounds are what the codecs report" {
  for level in -1..<=13 {
    assert_eq(
      @deflate.Encoder(level~).memory_usage(),
      @deflate.encoder_memory_bound(level~).to_int(),
    )
    assert_eq(
      @zlib.Encoder(level~).memory_usage(),
      @zlib.encoder_memory_bound(level~).to_int(),
    )
    assert_eq(
      @gzip.Encoder(level~).memory_usage(),
      @gzip.encoder_memory_bound(level~).to_int(),
    )
  }
  assert_eq(
    @deflate.Decoder().memory_usage(),
    @deflate.decoder_memory_bound().to_int(),
  )
  assert_eq(
    @zlib.Decoder().memory_usage(),
    @zlib.decoder_memory_bound().to_int(),
  )
  assert_eq(@gzip.decoder_memory_bound(keep_header=false).to_int(), 46592)
  assert_eq(@gzip.decoder_memory_bound(max_header_bytes=100).to_int(), 46692)
}

///|
test "the bounds hold for the reviewer's cases and saturate past 2^62" {
  // zlib with a dictionary: its 4-byte id is in the header.
  let zlib = @zlib.compress(b"", level=0, dictionary=b"x")
  assert_true(zlib.length().to_int64() <= @zlib.compress_bound(0L))
  // A flush splits the stream: its empty block, and the final block after.
  for level in [0, 1, 6, 9, 10, 11, 12] {
    let encoder = @deflate.Encoder(level~)
    let out = FixedArray::make(256, b'\x00')
    let _ = encoder.step_into(b"x", out, action=Flush)
    let first = encoder.last_produced()
    let _ = encoder.step_into(b"", out, action=Finish)
    let total = first + encoder.last_produced()
    assert_true(total.to_int64() <= @deflate.compress_bound(1L) + 10L)
  }
  let most = 0x7FFFFFFFFFFFFFFFL
  assert_eq(@deflate.compress_bound(most), most)
  assert_eq(@zlib.compress_bound(most), most)
  assert_eq(@gzip.compress_bound(most), most)
  assert_true(@deflate.compress_bound(1L << 62) > 1L << 62)
  assert_eq(
    @gzip.decoder_memory_bound(max_header_bytes=0x7fffffff),
    46592L + 0x7fffffffL,
  )
}

///|
test "a block that a last match carries past 65,535 bytes is within the bound" {
  // The reviewer's input: incompressible, but with a 4-byte repeat at the
  // end of each 65,534 bytes, so that at level 1 each block runs 4 bytes
  // past 65,534 and is stored as two blocks.
  let bytes = incompressible(200000, 1).to_array()
  for p in [65534, 131072, 196610] {
    for k in 0..<4 {
      bytes[p + k] = bytes[p - 128 + k]
    }
  }
  let input = Bytes::from_array(bytes)
  for level in 1..<=12 {
    let raw = @deflate.compress(input, level~)
    assert_true(raw.length().to_int64() <= @deflate.compress_bound(200000L))
    let zlib = @zlib.compress(input, level~)
    assert_true(zlib.length().to_int64() <= @zlib.compress_bound(200000L))
    let gzip = @gzip.compress(input, level~)
    assert_true(gzip.length().to_int64() <= @gzip.compress_bound(200000L))
  }
  // At level 1 the old count, a stored block per 65,535 bytes, falls short.
  let raw = @deflate.compress(input, level=1)
  assert_true(raw.length() > 200000 + 5 * 4 + 1)
}
