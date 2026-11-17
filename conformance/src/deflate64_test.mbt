///|
test "Deflate64 long matches keep the byte-stream contract and fuzz without aborts" {
  // Final fixed block: literal 'a', code 285 + extra 65535, distance 1,
  // EOB. The 65538-byte match must suspend beyond the 64 KiB window.
  let stream = b"\x4b\x1c\xfd\xff\x07\x00"
  let make = () => @codec_harness.ByteDecoder::new(@deflate64.Decoder())
  let full = @codec_harness.check_splits(make, stream, memory_limit=Some(79384))
  assert_eq(full.output, Bytes::make(65539, b'a'))
  assert_true(full.error is None)
  @codec_harness.check_truncation(make, stream, full)
  @codec_harness.check_trailing(make, stream, full, garbage=[
    b"\x00", b"\xff\xff",
  ])
  @codec_harness.check_member(
    () => @codec_harness.ByteDecoder::new(@deflate64.Decoder(until=EndOfMember)),
    stream,
    b"next member",
    full,
  )
  @codec_harness.check_reset(make, stream, b"\x03\x00")
  let _ = @codec_harness.fuzz(
    make,
    stream,
    seed=6409,
    rounds=400,
    memory_limit=Some(79384),
  )
}
