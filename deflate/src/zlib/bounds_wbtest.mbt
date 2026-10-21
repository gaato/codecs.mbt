///|
/// What a raw DEFLATE decoder reports without a dictionary.
const INNER : Int32 = 74240

///|
/// Checks the limits RESOURCE_BOUNDS.md states, after a step that had `room`
/// bytes of output, for a decoder given a dictionary of `dictionary` bytes.
fn check_bounds(
  d : Decoder,
  room : Int32,
  dictionary~ : Int32 = 0,
) -> Unit raise {
  assert_true(d.last_produced() <= room)
  assert_true(d.hdr_len <= HEADER_MAX && d.hdr.length() == HEADER_MAX)
  let kept = dictionary.min(32768)
  // One inner decoder, with the dictionary only for a stream that names it.
  let inner = match d.inner {
    Some(inner) => {
      let expected = if d.inner_dictionary { INNER + kept } else { INNER }
      assert_eq(inner.memory_usage(), expected)
      expected
    }
    None => 0
  }
  if d.state is Data(_) {
    assert_true(d.inner is Some(_))
  }
  assert_eq(d.memory_usage(), inner + kept)
  assert_true(d.memory_usage() <= INNER + 2 * kept)
}

///|
test "output slices, header bytes and reported memory stay within their bounds" {
  for v in vectors {
    let decoder = Decoder()
    assert_eq(decoder.memory_usage(), 0)
    let (got, _) = @fixtures.drive(
      decoder,
      v.input(),
      next_in=() => 1,
      next_out=() => 997,
      check=(d, room) => check_bounds(d, room),
    )
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
    assert_eq(decoder.memory_usage(), INNER)
  }
  for entry in dictionary_vectors {
    let (v, dictionary) = entry
    let dictionary = @fixtures.decode64(dictionary)
    let decoder = Decoder(dictionary~)
    let (got, _) = @fixtures.drive(
      decoder,
      v.input(),
      next_in=() => 3,
      next_out=() => 4096,
      check=(d, room) => check_bounds(d, room, dictionary=dictionary.length()),
    )
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
  }
  inspect(INNER + 2 * 32768, content="139776")
}

///|
test "one inner decoder, made for the kind of stream the header names" {
  let (named, dictionary) = dictionary_vectors[1]
  let dictionary = @fixtures.decode64(dictionary)
  let plain = vector("small_level6")
  let decoder = Decoder(dictionary~)
  let kept = dictionary.length().min(32768)
  let run = (v : Vector) => {
    let (got, _) = @fixtures.drive(
      decoder,
      v.input(),
      next_in=() => 100,
      next_out=() => 1000,
      check=(d, room) => check_bounds(d, room, dictionary=dictionary.length()),
    )
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
    decoder.reset()
  }
  // Only the dictionary's copy before the first header.
  assert_eq(decoder.memory_usage(), kept)
  run(named)
  let first = decoder.inner
  assert_eq(decoder.memory_usage(), INNER + 2 * kept)
  // The same kind again: the same inner decoder, reset.
  run(named)
  assert_true(physical_equal(decoder.inner.unwrap(), first.unwrap()))
  // A stream that names no dictionary: replaced by one without it.
  run(plain)
  assert_false(decoder.inner_dictionary)
  assert_eq(decoder.memory_usage(), INNER + kept)
  run(named)
  assert_true(decoder.inner_dictionary)
}
