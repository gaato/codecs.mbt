///|
/// What `memory_usage` reports without a dictionary.
const BOUND : Int32 = WINDOW_SIZE + LINK_TABLE_BYTES + STAGED_BYTES

///|
/// Checks the limits RESOURCE_BOUNDS.md states, after a step that had `room`
/// bytes of output.
fn check_bounds(d : Decoder, room : Int32) -> Unit raise {
  assert_true(d.last_produced() <= room)
  let dictionary = match d.dictionary {
    Some(bytes) => bytes.length()
    None => 0
  }
  assert_true(dictionary <= WINDOW_SIZE)
  assert_eq(d.memory_usage(), BOUND + dictionary)
}

///|
test "output slices and reported memory stay within their bounds" {
  inspect(BOUND, content="74240")
  for v in vectors {
    guard v.size <= 300000 else { continue }
    let (got, _) = @fixtures.drive(
      Decoder(),
      v.input(),
      next_in=() => 1,
      next_out=() => 997,
      check=check_bounds,
    )
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "only the last 32 KiB of a dictionary are kept" {
  for entry in dictionary_vectors {
    let (v, dictionary) = entry
    let dictionary = @fixtures.decode64(dictionary)
    let decoder = Decoder(dictionary~)
    let (got, _) = @fixtures.drive(
      decoder,
      v.input(),
      next_in=() => 333,
      next_out=() => 4096,
      check=check_bounds,
    )
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
    assert_eq(
      decoder.memory_usage(),
      BOUND + dictionary.length().min(WINDOW_SIZE),
      msg=v.name,
    )
  }
  inspect(
    Decoder(dictionary=Bytes::make(40000, b'd')).memory_usage(),
    content="107008",
  )
}
