///|
fn reset_input(seed : UInt32, mask : UInt32, size : Int32) -> Bytes {
  let mut state = seed
  Bytes::makei(size, _ => {
    state = state * 1664525U + 1013904223U
    ((state >> 24) & mask).to_byte()
  })
}

///|
fn[E : @codec_bytes.Encode] finish_after_reset(
  encoder : E,
  input : Bytes,
) -> Bytes raise {
  let out = Buffer()
  let room = FixedArray::make(4096, b'\x00')
  let mut pos = 0
  for ;; {
    let status = encoder.step(input[pos:], room.mut_view(), action=Finish)
    pos += encoder.last_consumed()
    out.write_bytes(Bytes::from_array(room[:encoder.last_produced()]))
    match status {
      Done => {
        assert_eq(pos, input.length())
        return out.to_bytes()
      }
      NeedMoreOutput => continue
      _ => fail("Finish must complete or wait for output")
    }
  }
}

///|
fn[E : @codec_bytes.Encode] check_reset_repro(
  make : () -> E,
  prefix : Bytes,
  input : Bytes,
  label : String,
) -> Unit raise {
  let reused = make()
  let room = FixedArray::make(1 << 17, b'\x00')
  assert_eq(
    reused.step(prefix, room.mut_view(), action=Continue),
    NeedMoreInput,
  )
  assert_eq(reused.last_consumed(), prefix.length())
  reused.reset()
  assert_eq(reused.last_consumed(), 0)
  assert_eq(reused.last_produced(), 0)
  let actual = finish_after_reset(reused, input)
  let expected = finish_after_reset(make(), input)
  assert_eq(actual.length(), expected.length(), msg=label)
  assert_true(actual == expected, msg=label)
}

///|
test "reset after Continue equals a fresh raw, zlib and gzip encoder at every level" {
  let prefix = reset_input(91U, 255U, 60000)
  let input = reset_input(92U, 30U, 100000)
  for level in 0..<=12 {
    check_reset_repro(
      () => @deflate.Encoder(level~),
      prefix,
      input,
      "raw/\{level}",
    )
    check_reset_repro(
      () => @zlib.Encoder(level~),
      prefix,
      input,
      "zlib/\{level}",
    )
    check_reset_repro(
      () => @gzip.Encoder(level~),
      prefix,
      input,
      "gzip/\{level}",
    )
  }
}
