///|
fn be16(n : Int32) -> Array[Byte] {
  [(n >> 8).to_byte(), n.to_byte()]
}

///|
/// An acTL chunk.
fn actl(frames : UInt32, plays~ : UInt32 = 0) -> Array[Byte] {
  chunk("acTL", Bytes::from_array([..be32(frames), ..be32(plays)]))
}

///|
/// An fcTL chunk.
fn fctl(
  sequence : UInt32,
  width : Int32,
  height : Int32,
  x~ : Int32 = 0,
  y~ : Int32 = 0,
  delay~ : (Int32, Int32) = (1, 10),
  dispose~ : Int32 = 0,
  blend~ : Int32 = 0,
) -> Array[Byte] {
  chunk(
    "fcTL",
    Bytes::from_array(
      [
        ..be32(sequence),
        ..be32(width.reinterpret_as_uint()),
        ..be32(height.reinterpret_as_uint()),
        ..be32(x.reinterpret_as_uint()),
        ..be32(y.reinterpret_as_uint()),
        ..be16(delay.0),
        ..be16(delay.1),
        dispose.to_byte(),
        blend.to_byte(),
      ],
    ),
  )
}

///|
/// fdAT chunks of `data`, `size` bytes each, numbered from `sequence`.
fn fdats(
  sequence : UInt32,
  data : Bytes,
  size~ : Int32 = 1 << 20,
) -> Array[Array[Byte]] {
  let out = []
  let mut at = 0
  let mut n = sequence
  while at < data.length() || out.is_empty() {
    let end = (at + size).min(data.length())
    out.push(chunk("fdAT", Bytes::from_array([..be32(n), ..data[at:end]])))
    n += 1
    at = end
  }
  out
}

///|
/// The zlib stream of random rows of a `width` x `height` 8-bit RGB frame,
/// and the rows.
fn frame_data(
  width : Int32,
  height : Int32,
  interlaced~ : Bool = false,
  seed~ : UInt32 = 3,
) -> (Bytes, Bytes) {
  let raw = raw_image(width, height, 24, interlaced~, seed~)
  (@zlib.compress(raw.filtered), raw.rows)
}

///|
/// An 8 x 6 RGB APNG: `chunks` after IHDR, with IEND.
fn apng_of(chunks : Array[Array[Byte]], interlaced~ : Bool = false) -> Bytes {
  png_of(
    [
      chunk(
        "IHDR",
        ihdr_data(8, 6, 8, 2, interlace=if interlaced { 1 } else { 0 }),
      ),
      ..chunks,
      chunk("IEND", b""),
    ],
  )
}

///|
/// The answers of a run, with each `Frame`'s place and controls.
fn frames_outline(
  png : Bytes,
  chunk~ : Int32 = 1 << 20,
  room~ : Int32 = 1 << 16,
) -> String {
  let decoder = Decoder()
  let lines = []
  let mut pos = 0
  let mut pending = png[0:0]
  for ;; {
    if pending.length() == 0 && pos < png.length() {
      let next = (pos + chunk).min(png.length())
      pending = png[pos:next]
      pos = next
    }
    let out = FixedArray::make(room.max(decoder.room_needed()), b'\x00')
    let status = decoder.step(pending, out.mut_view(), end=pos == png.length()) catch {
      CodecError(kind, message) => {
        lines.push("\{@debug.to_string(kind)}: \{message}")
        return lines.join("\n")
      }
    }
    pending = pending[decoder.last_consumed():]
    match status {
      Frame =>
        lines.push(
          "Frame \{decoder.frame_x()},\{decoder.frame_y()} \{decoder.frame_width()}x\{decoder.frame_height()} \{decoder.in_animation()} \{decoder.delay_numerator()}/\{decoder.delay_denominator()} \{@debug.to_string(decoder.dispose())} \{@debug.to_string(decoder.blend())}",
        )
      Rows => {
        let last = lines.length() - 1
        if !lines[last].has_prefix("rows") {
          lines.push("rows")
        }
      }
      Metadata => lines.push("Metadata \{decoder.metadata_type()}")
      FrameEnd => lines.push("FrameEnd")
      Done => {
        lines.push(
          "Done \{decoder.animated()} \{decoder.frame_count()} \{decoder.plays()}",
        )
        return lines.join("\n")
      }
      _ => ()
    }
  }
}

///|
test "APNG: the default image and two frames, their rows and controls" {
  let (z0, r0) = frame_data(8, 6, seed=1)
  let (z1, r1) = frame_data(3, 2, seed=2)
  let (z2, r2) = frame_data(8, 1, seed=3)
  let second = fdats(2, z1, size=7)
  let next = 2U + second.length().reinterpret_as_uint()
  let png = apng_of(
    [
      actl(3, plays=2),
      fctl(0, 8, 6, delay=(1, 0), dispose=2),
      ..idat_chunks(z0, 50),
      fctl(1, 3, 2, x=5, y=4, dispose=2, blend=1),
      ..second,
      fctl(next, 8, 1, y=5, delay=(3, 100), dispose=1),
      ..fdats(next + 1, z2),
    ],
  )
  inspect(
    frames_outline(png),
    content=(
      #|Frame 0,0 8x6 true 1/100 Background Source
      #|rows
      #|FrameEnd
      #|Frame 5,4 3x2 true 1/10 Previous Over
      #|rows
      #|FrameEnd
      #|Frame 0,5 8x1 true 3/100 Background Source
      #|rows
      #|FrameEnd
      #|Done true 3 2
    ),
  )
  // The rows of every frame, one after another, whatever the split.
  let all = Bytes::from_array([..r0, ..r1, ..r2])
  for split in [(1 << 20, 1 << 16), (1, 1), (5, 13)] {
    let decoded = run(Decoder(), png, chunk=split.0, room=split.1)
    assert_true(decoded.error is None)
    assert_eq(decoded.output, all)
  }
  // Rows of a frame are as wide as the frame; the buffers are the image's.
  let decoded = run(Decoder(), png)
  assert_eq(decoded.peak_memory, BASE_MEMORY + 2 * (1 + 24))
}

///|
test "APNG: a default image outside the animation, interlaced frames" {
  let (z0, r0) = frame_data(8, 6, interlaced=true, seed=1)
  let (z1, r1) = frame_data(5, 5, interlaced=true, seed=2)
  let png = apng_of(
    [
      actl(1),
      ..idat_chunks(z0, 100),
      fctl(0, 5, 5, x=1, y=1),
      ..fdats(1, z1, size=9),
    ],
    interlaced=true,
  )
  inspect(
    frames_outline(png),
    content=(
      #|Frame 0,0 8x6 false 0/100 Keep Source
      #|rows
      #|FrameEnd
      #|Frame 1,1 5x5 true 1/10 Keep Source
      #|rows
      #|FrameEnd
      #|Done true 1 0
    ),
  )
  let decoded = run(Decoder(), png, chunk=3, room=1)
  assert_eq(decoded.output, Bytes::from_array([..r0, ..r1]))
  // Without animation, the default image alone, and nothing counted.
  let decoder = Decoder(animation=false)
  let still = run(decoder, png)
  assert_eq(still.output, r0)
  inspect(decoder.ignored_chunks(), content="0")
  assert_false(decoder.animated())
}

///|
test "APNG: text between the fdAT chunks of a frame, inflated by the second zlib decoder" {
  let (z0, _) = frame_data(8, 6, seed=1)
  let (z1, _) = frame_data(8, 6, seed=2)
  let half = z1.length() / 2
  let ztxt = chunk(
    "zTXt",
    Bytes::from_array([..b"k\x00\x00", ..@zlib.compress(b"between")]),
  )
  let png = apng_of(
    [
      actl(1),
      ..idat_chunks(z0, 100),
      fctl(0, 8, 6),
      ..fdats(1, z1[:half].to_owned()),
      ztxt,
      ..fdats(2, z1[half:].to_owned()),
    ],
  )
  let decoder = Decoder(report=["zTXt"])
  let decoded = run(decoder, png, chunk=7, room=24)
  assert_true(decoded.error is None)
  let text = b"k\x00between"
  inspect(
    decoded.answers
    .filter(a => !a.has_prefix("Rows") && a != "NeedMoreInput")
    .join(" "),
    content="Header Frame FrameEnd Frame Metadata zTXt FrameEnd Done",
  )
  // The block comes out among the frame's rows, which are the rows still.
  let output = decoded.output
  let mut at = -1
  for i in 0..<=(output.length() - text.length()) {
    if output[i:i + text.length()] == text[:] {
      at = i
      break
    }
  }
  assert_true(at > 144 && at < 288)
  assert_eq(
    Bytes::from_array([..output[:at], ..output[at + text.length():]]),
    Bytes::from_array(
      [
        ..run(
          Decoder(),
          apng_of(
            [actl(1), ..idat_chunks(z0, 100), fctl(0, 8, 6), ..fdats(1, z1)],
          ),
        ).output,
      ],
    ),
  )
}

///|
test "APNG: chunks that only an APNG reader would miss leave a still image" {
  let (z0, r0) = frame_data(8, 6, seed=1)
  let (z1, _) = frame_data(8, 6, seed=2)
  let animation = [fctl(0, 8, 6), ..fdats(1, z1)]
  let cases = [
    // No acTL; acTL after IDAT; acTL of no frames.
    [..idat_chunks(z0, 100), ..animation],
    [..idat_chunks(z0, 100), actl(1), ..animation],
    [actl(0), ..idat_chunks(z0, 100), ..animation],
  ]
  for chunks in cases {
    let decoded = run(Decoder(), apng_of(chunks))
    assert_true(decoded.error is None)
    assert_eq(decoded.output, r0)
  }
  // An fcTL before acTL counts once acTL has come.
  let early = run(
    Decoder(),
    apng_of(
      [
        fctl(0, 8, 6),
        actl(2),
        ..idat_chunks(z0, 100),
        fctl(1, 8, 6),
        ..fdats(2, z1),
      ],
    ),
  )
  assert_true(early.error is None)
  inspect(early.answers.filter(a => a == "Frame").length(), content="2")
}

///|
test "APNG: refusals" {
  let (z0, _) = frame_data(8, 6, seed=1)
  let (z1, _) = frame_data(8, 6, seed=2)
  let idat = idat_chunks(z0, 100)
  let refused = (chunks : Array[Array[Byte]]) => {
    let lines = frames_outline(apng_of(chunks)).split("\n").to_array()
    lines[lines.length() - 1].to_owned()
  }
  inspect(
    refused([actl(1), ..idat, fctl(0, 8, 6), ..fdats(2, z1)]),
    content="Corrupt: sequence number 2 where 1 was due",
  )
  inspect(
    refused([actl(1), ..idat, fctl(1, 8, 6), ..fdats(2, z1)]),
    content="Corrupt: sequence number 1 where 0 was due",
  )
  inspect(
    refused([actl(1), ..idat, ..fdats(0, z1)]),
    content="Corrupt: fdAT without an fcTL before it",
  )
  inspect(
    refused([actl(2), ..idat, fctl(0, 8, 6), fctl(1, 8, 6), ..fdats(2, z1)]),
    content="Corrupt: an fcTL whose frame has no data",
  )
  inspect(
    refused([actl(1), ..idat, fctl(0, 8, 6)]),
    content="Corrupt: an fcTL whose frame has no data",
  )
  inspect(
    refused(
      [
        actl(1),
        ..idat,
        fctl(0, 8, 6),
        ..fdats(1, z1),
        fctl(2, 8, 6),
        ..fdats(3, z1),
      ],
    ),
    content="Corrupt: acTL says 1 frames, and there are 2",
  )
  inspect(
    refused([actl(3), ..idat, fctl(0, 8, 6), ..fdats(1, z1)]),
    content="Corrupt: acTL says 3 frames, and there are 1",
  )
  inspect(
    refused([actl(1), actl(1), ..idat, fctl(0, 8, 6), ..fdats(1, z1)]),
    content="Corrupt: a second acTL",
  )
  inspect(
    refused([actl(1), ..idat, fctl(0, 4, 4, x=5), ..fdats(1, z1)]),
    content="Corrupt: fcTL: a frame of 4x4 at 5,0 outside the image's 8x6",
  )
  inspect(
    refused([actl(1), fctl(0, 4, 4), ..idat]),
    content="Corrupt: fcTL: the default image's frame is not the whole image",
  )
  inspect(
    refused([actl(1), ..idat, fctl(0, 8, 6, dispose=3), ..fdats(1, z1)]),
    content="Corrupt: fcTL: dispose op 3",
  )
  inspect(
    refused([actl(1), fctl(0, 8, 6), fctl(1, 8, 6), ..idat]),
    content="Corrupt: fcTL out of order",
  )
  inspect(
    refused([actl(1), ..fdats(0, z1), ..idat]),
    content="Corrupt: fdAT out of order",
  )
  inspect(
    refused(
      [actl(1), ..idat, chunk("fcTL", b"\x00\x00\x00\x00"), ..fdats(1, z1)],
    ),
    content="Corrupt: an fcTL of 4 bytes",
  )
  inspect(
    refused([actl(1), ..idat, fctl(0, 8, 6), chunk("fdAT", b"\x00\x01")]),
    content="Corrupt: an fdAT of 2 bytes",
  )
  inspect(
    refused(
      [
        actl(1),
        ..idat,
        fctl(0, 8, 6),
        chunk("fdAT", Bytes::from_array([..be32(1), ..z1]), bad_crc=1),
      ],
    ),
    content="ChecksumMismatch: the CRC of fdAT does not match",
  )
  // A frame whose zlib stream is cut: its rows come, then the error at the
  // chunk that ends the frame.
  let cut = z1[:z1.length() / 2].to_owned()
  let lines = frames_outline(
    apng_of(
      [
        actl(2),
        ..idat,
        fctl(0, 8, 6),
        ..fdats(1, cut),
        fctl(2, 8, 6),
        ..fdats(3, z1),
      ],
    ),
  )
  inspect(
    lines,
    content=(
      #|Frame 0,0 8x6 false 0/100 Keep Source
      #|rows
      #|FrameEnd
      #|Frame 0,0 8x6 true 1/10 Keep Source
      #|rows
      #|Corrupt: the image data ends before the image's last row
    ),
  )
}
