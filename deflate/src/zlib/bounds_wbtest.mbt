///|
/// What a raw DEFLATE decoder reports, with a dictionary or without.
const INNER : Int32 = 46592

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
  // A view of the dictionary's last 32 KiB, not counted.
  let kept = match d.dictionary {
    Some(view) => view.length()
    None => 0
  }
  assert_eq(kept, dictionary.min(32768))
  assert_true(d.inner.kept_bytes() <= 5)
  assert_eq(d.memory_usage(), INNER)
}

///|
test "output slices, header bytes and reported memory stay within their bounds" {
  for v in vectors {
    let decoder = Decoder()
    assert_eq(decoder.memory_usage(), INNER)
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
    assert_eq(decoder.memory_usage(), INNER)
  }
}

///|
test "one inflater, given the dictionary when the header names it" {
  let (named, dictionary) = dictionary_vectors[1]
  let dictionary = @fixtures.decode64(dictionary)
  let plain = vector("small_level6")
  let decoder = Decoder(dictionary~)
  let inner = decoder.inner
  let run = (v : Vector) => {
    let (got, _) = @fixtures.drive(
      decoder,
      v.input(),
      next_in=() => 100,
      next_out=() => 1000,
      check=(d, room) => check_bounds(d, room, dictionary=dictionary.length()),
    )
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
  }
  run(named)
  // The inflater reads a view of the caller's bytes, not a copy.
  let view = decoder.inner.dictionary()
  assert_true(physical_equal(view.data(), dictionary))
  assert_eq(view.length(), dictionary.length().min(32768))
  decoder.reset()
  // A stream that names no dictionary: the same inflater, without it.
  run(plain)
  assert_eq(decoder.inner.dictionary().length(), 0)
  decoder.reset()
  run(named)
  assert_true(physical_equal(decoder.inner, inner))
  assert_eq(decoder.memory_usage(), INNER)
}

///|
/// What the raw DEFLATE encoder reports at `level` (RESOURCE_BOUNDS.md).
fn raw_encoder_bound(level : Int32) -> Int32 {
  match level {
    0 => 131077
    1 => 361948
    2 | 3 | 4 => 542172
    _ => 542516
  }
}

///|
test "the encoder reports the raw encoder's bound after every step" {
  let input = @fixtures.sample(10, 150000)
  let dictionary = @fixtures.sample(11, 40000)
  for level in 0..<=9 {
    let bound = raw_encoder_bound(level)
    for encoder in [Encoder(level~), Encoder(level~, dictionary~)] {
      assert_eq(encoder.memory_usage(), bound)
      let rng = @fixtures.Rng::new(level.reinterpret_as_uint())
      let _ = @fixtures.encode(
        encoder,
        input,
        next_in=() => 1 + rng.below(40000),
        next_out=() => rng.below(3000),
        flush_every=50000,
        check=(e, _) => {
          assert_eq(e.memory_usage(), bound)
          assert_true(e.framing.length() <= HEADER_MAX)
        },
      )
    }
  }
}
