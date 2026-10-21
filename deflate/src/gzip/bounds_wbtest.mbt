///|
/// Checks the limits RESOURCE_BOUNDS.md states, after a step that had `room`
/// bytes of output.
fn check_bounds(d : Decoder, room : Int32) -> Unit raise {
  assert_true(d.last_produced() <= room)
  assert_true(d.hdr_len <= HDR_SIZE && d.hdr.length() == HDR_SIZE)
  // The header's variable fields, within the limit.
  let held = [d.extra, d.name, d.comment].fold(init=0, (n, b) => {
    n +
    (match b {
      Some(buffer) => buffer.length()
      None => 0
    })
  })
  let kept = match d.header {
    Some(h) =>
      [h.extra, h.name, h.comment].fold(init=0, (n, b) => {
        n +
        (match b {
          Some(bytes) => bytes.length()
          None => 0
        })
      })
    None => 0
  }
  assert_true(held <= d.held && kept <= d.held)
  assert_true(d.held <= d.max_header_bytes)
  assert_eq(d.memory_usage(), d.inner.memory_usage() + d.held)
  assert_true(d.memory_usage() <= 74240 + d.max_header_bytes)
}

///|
test "output slices, header fields and reported memory stay within their bounds" {
  for v in vectors {
    let (got, _) = @fixtures.drive(
      Decoder(),
      v.input(),
      next_in=() => 1,
      next_out=() => 997,
      check=check_bounds,
    )
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
  }
  // The largest extra field of the vectors, 60,000 bytes, at the limit.
  let v = vector("header_large_extra")
  let decoder = Decoder(max_header_bytes=60000)
  let mut peak = 0
  let _ = @fixtures.drive(
    decoder,
    v.input(),
    next_in=() => 4096,
    next_out=() => 4096,
    check=(d, room) => {
      check_bounds(d, room)
      peak = peak.max(d.memory_usage())
    },
  )
  inspect(peak, content="134240")
}

///|
test "the encoder reports the raw encoder's bound and its header after every step" {
  let input = @fixtures.sample(10, 150000)
  let named : Header = {
    text: true,
    mtime: 1,
    xfl: b'\x00',
    os: b'\x03',
    extra: Some(Bytes::make(65535, b'e')),
    name: Some(b"name"),
    comment: Some(b"comment"),
  }
  for level in [0, 1, 6, 9] {
    for header in [None, Some(named)] {
      let encoder = Encoder(level~, header?)
      // The fixed part, and the extra field with its length, the name and
      // the comment with their zeros.
      let held = match header {
        Some(_) => 10 + 2 + 65535 + 5 + 8
        None => 10
      }
      assert_eq(encoder.header.length(), held)
      assert_eq(encoder.memory_usage(), 689394 + held)
      let rng = @fixtures.Rng::new(level.reinterpret_as_uint())
      let _ = @fixtures.encode(
        encoder,
        input,
        next_in=() => 1 + rng.below(40000),
        next_out=() => rng.below(3000),
        flush_every=50000,
        check=(e, _) => {
          assert_eq(e.memory_usage(), 689394 + held)
          // The header, or the 8-byte trailer.
          assert_true(e.framing.length() == held || e.framing.length() == 8)
        },
      )
    }
  }
}
