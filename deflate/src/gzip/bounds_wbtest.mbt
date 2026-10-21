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
