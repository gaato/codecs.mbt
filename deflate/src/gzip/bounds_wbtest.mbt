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
      Some(field) => field.len
      None => 0
    })
  })
  // What the fields' arrays take, room to spare included.
  let allocated = [d.extra, d.name, d.comment].fold(init=0, (n, b) => {
    n +
    (match b {
      Some(field) => field.data.length()
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
  assert_true(d.inner.kept_bytes() <= 5)
  assert_eq(
    d.inner.memory_usage(),
    decoder_memory_bound(keep_header=false).to_int(),
  )
  let gathering = d.extra is Some(_) ||
    d.name is Some(_) ||
    d.comment is Some(_)
  assert_eq(
    d.memory_usage(),
    d.inner.memory_usage() + (if gathering { allocated } else { d.held }),
  )
  assert_true(
    d.memory_usage() <=
    decoder_memory_bound(max_header_bytes=d.max_header_bytes).to_int(),
  )
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
  inspect(peak, content="106592")
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
  for level in 0..<=12 {
    let bound = @deflater.memory_bound(level).to_int()
    for header in [None, Some(named)] {
      let encoder = Encoder(level~, header?)
      // The fixed part, and the extra field with its length, the name and
      // the comment with their zeros.
      let held = match header {
        Some(_) => 10 + 2 + 65535 + 5 + 8
        None => 10
      }
      assert_eq(encoder.header.length(), held)
      assert_eq(encoder.memory_usage(), bound + held)
      let rng = @fixtures.Rng::new(level.reinterpret_as_uint())
      let _ = @fixtures.encode(
        encoder,
        input,
        next_in=() => 1 + rng.below(40000),
        next_out=() => rng.below(3000),
        flush_every=50000,
        check=(e, _) => {
          assert_eq(e.memory_usage(), bound + held)
          // The header, or the 8-byte trailer.
          assert_true(e.framing.length() == held || e.framing.length() == 8)
        },
      )
    }
  }
}

///|
test "a name that grows to the limit is counted with the room allocated for it" {
  // A header with FNAME and 32,769 bytes of name, no terminator yet: the
  // name's array has grown by doubling, and memory_usage counts all of it.
  let limit = 32769
  let header = Bytes::from_array([
    b'\x1f', b'\x8b', b'\x08', b'\x08', b'\x00', b'\x00', b'\x00', b'\x00', b'\x00',
    b'\xff',
  ])
  let input = header + Bytes::make(limit, b'n')
  let out = FixedArray::make(16, b'\x00')
  for piece in [1, 7, 4096, input.length()] {
    let d = Decoder(max_header_bytes=limit)
    let mut pos = 0
    while pos < input.length() {
      let end = (pos + piece).min(input.length())
      let status = d.step_into(input[pos:end], out, end=false)
      assert_true(status is NeedMoreInput)
      pos = end
      check_bounds(d, out.length())
    }
    guard d.name is Some(name) else { fail("no name") }
    assert_eq(name.len, limit)
    assert_eq(d.memory_usage(), d.inner.memory_usage() + name.data.length())
    assert_true(
      d.memory_usage() <= decoder_memory_bound(max_header_bytes=limit).to_int(),
    )
  }
}

///|
test "the header's size counts the fields it has" {
  let bare : Header = {
    text: true,
    mtime: 0,
    xfl: b'\x00',
    os: b'\x03',
    extra: None,
    name: None,
    comment: None,
  }
  assert_eq(header_size(None), 10)
  assert_eq(header_size(Some(bare)), 10)
  assert_eq(header_size(Some({ ..bare, name: Some(b"a.txt"), })), 16)
  for
    header in [
      bare,
      { ..bare, extra: Some(b"xy"), },
      { ..bare, comment: Some(b"c"), },
    ] {
    assert_eq(
      Encoder(header~).memory_usage().to_int64(),
      encoder_memory_bound(header~),
    )
  }
}
