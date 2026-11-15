///|
/// The lengths of the frames `input` holds, one `frame_size` at a time.
fn frame_lengths(input : BytesView) -> Array[Int64] raise @codec.CodecError {
  let lengths = []
  let mut rest = input
  while rest.length() > 0 {
    let n = frame_size(rest)
    lengths.push(n)
    rest = rest[n.to_int():]
  }
  lengths
}

///|
/// The kind of error `f` raises.
fn kind_of(f : () -> Unit raise @codec.CodecError) -> @codec.ErrorKind raise {
  try f() catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("no error")
  }
}

///|
test "frame_size walks every vector's frames to its end" {
  for v in vectors {
    let input = v.input()
    let lengths = frame_lengths(input)
    let total = lengths.fold(init=0L, (a, n) => a + n)
    assert_eq(total, input.length().to_int64(), msg=v.name)
    assert_true(lengths.length() >= 1, msg=v.name)
  }
  let two = vector("gen/two_frames").input()
  assert_eq(frame_lengths(two).length(), 2)
  // A frame, two skippable frames (one empty) and a frame.
  let between = vector("gen/skippable_between").input()
  let lengths = frame_lengths(between)
  assert_eq(lengths.length(), 4)
  assert_eq(lengths[1], 8L + 24L)
  assert_eq(lengths[2], 8L)
}

///|
test "inspect_frame reads what the encoder wrote" {
  let text = Bytes::makei(5000, i => (b'a'.to_int() + i % 23).to_byte())
  let frame = compress(text)
  guard inspect_frame(frame) is Zstd(info) else { fail("not a frame") }
  assert_eq(info.content_size, Some(5000UL))
  assert_eq(info.dictionary_id, 0U)
  assert_eq(info.has_checksum, true)
  assert_eq(info.single_segment, true)
  assert_eq(info.window_size, 5000UL)
  assert_eq(frame_size(frame), frame.length().to_int64())
  let no_checksum = compress(text, checksum=false)
  guard inspect_frame(no_checksum) is Zstd(info) else { fail("not a frame") }
  assert_eq(info.has_checksum, false)
  assert_eq(frame_size(no_checksum), no_checksum.length().to_int64())
  // A frame followed by other bytes: the size stops at the frame's end.
  assert_eq(frame_size(frame + b"tail"), frame.length().to_int64())
}

///|
test "a frame cut anywhere is Truncated, a bad one Corrupt" {
  let v = vector("gen/text_level3").input()
  let n = frame_size(v).to_int()
  for cut in 0..<n {
    assert_eq(
      kind_of(() => ignore(frame_size(v[:cut]))),
      Truncated,
      msg="\{cut}",
    )
  }
  // The reserved bit of the frame header descriptor.
  let reserved : Array[Byte] = [0x28, 0xb5, 0x2f, 0xfd, 0x08, 0x00]
  assert_eq(
    kind_of(() => ignore(inspect_frame(Bytes::from_array(reserved)))),
    Corrupt,
  )
  // A block of the reserved type (3) after a single-segment header.
  let bad_block : Array[Byte] = [
    0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x00, 0x07, 0x00, 0x00,
  ]
  assert_eq(
    kind_of(() => ignore(frame_size(Bytes::from_array(bad_block)))),
    Corrupt,
  )
  assert_eq(kind_of(() => ignore(inspect_frame(b"\x00\x01\x02\x03"))), Corrupt)
  assert_eq(kind_of(() => ignore(inspect_frame(b"\x28\xb5"))), Truncated)
}

///|
test "skippable frames: written, read back, skipped by the decoder" {
  // RFC 9842's dcz header: variant 0xE, 32 bytes (a SHA-256).
  let hash = Bytes::makei(32, i => i.to_byte())
  let header = skippable_frame(0xE, hash)
  assert_eq(header[:8], b"\x5e\x2a\x4d\x18\x20\x00\x00\x00")
  assert_eq(header.length(), 40)
  assert_eq(inspect_frame(header), Skippable(variant=14, size=32))
  let (variant, data) = read_skippable_frame(header + b"rest")
  assert_eq(variant, 14)
  assert_eq(data, hash[:])
  assert_eq(frame_size(header), 40L)
  // Only the variant's low four bits are used.
  assert_eq(skippable_frame(0x13, b"x")[:4], b"\x53\x2a\x4d\x18")
  let text = Bytes::makei(3000, i => (i % 251).to_byte())
  assert_eq(decompress(header + compress(text) + skippable_frame(0, b"")), text)
  assert_eq(
    kind_of(() => ignore(read_skippable_frame(compress(text)))),
    Corrupt,
  )
  assert_eq(kind_of(() => ignore(read_skippable_frame(header[:39]))), Truncated)
  // Cut inside a skippable frame's header, and inside its data.
  for cut in [4, 7] {
    assert_eq(kind_of(() => ignore(inspect_frame(header[:cut]))), Truncated)
  }
  assert_eq(kind_of(() => ignore(frame_size(header[:39]))), Truncated)
}
