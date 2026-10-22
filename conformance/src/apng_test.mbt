// gaato/png over animated PNGs (apng_vectors_test.mbt): every frame against
// the png crate's, and under the harness's checks through the image adapter.

///|
/// The frames of an APNG as gaato/png gives them: for each, its fcTL's
/// values (`-` for a default image outside the animation) and its rows.
fn decode_frames(
  input : Bytes,
  animation~ : Bool = true,
) -> (@png.Decoder, Array[(String, Int32, Int32, Bytes)]) raise {
  let decoder = @png.Decoder(animation~)
  let frames : Array[(String, Int32, Int32, Buffer)] = []
  let mut out = FixedArray::make(0, b'\x00')
  let mut rest = input[:]
  for ;; {
    if out.length() < decoder.room_needed() {
      out = FixedArray::make(decoder.room_needed() * 8, b'\x00')
    }
    let status = decoder.step_into(rest, out, end=true)
    rest = rest[decoder.last_consumed():]
    match status {
      Frame => {
        let size = "\{decoder.frame_width()}x\{decoder.frame_height()}"
        let fields = if decoder.in_animation() {
          let dispose = match decoder.dispose() {
            Keep => 0
            Background => 1
            Previous => 2
          }
          let blend = if decoder.blend() is Over { 1 } else { 0 }
          "\{decoder.frame_x()},\{decoder.frame_y()} \{size} \{decoder.delay_numerator()}/\{decoder.delay_denominator()} \{dispose} \{blend}"
        } else {
          "- \{size}"
        }
        frames.push(
          (fields, decoder.frame_width(), decoder.frame_height(), Buffer()),
        )
      }
      Rows =>
        frames[frames.length() - 1].3.write_bytes(
          Bytes::from_array(out[:decoder.last_produced()]),
        )
      Done => break
      _ => ()
    }
  }
  (decoder, frames.map(f => (f.0, f.1, f.2, f.3.to_bytes())))
}

///|
/// What the reference writes, read as the specification says to apply it:
/// a delay's denominator of 0 is 100, and the first frame's dispose op of
/// PREVIOUS (2) is BACKGROUND (1).
fn as_applied(reference : StringView) -> String {
  let parts = reference.split("; ").map(p => p.to_owned()).to_array()
  for i in 1..<parts.length() {
    let fields = parts[i].split(" ").map(f => f.to_owned()).to_array()
    guard fields.length() == 6 else { continue }
    if fields[2].strip_suffix("/0") is Some(numerator) {
      fields[2] = "\{numerator}/100"
    }
    if i == 1 && fields[3] == "2" {
      fields[3] = "1"
    }
    parts[i] = fields.join(" ")
  }
  parts.join("; ")
}

///|
/// The line the reference writes for what gaato/png gives.
fn describe_frames(
  decoder : @png.Decoder,
  frames : Array[(String, Int32, Int32, Bytes)],
) -> String {
  let head = "ok \{decoder.width()}x\{decoder.height()} " +
    (if decoder.animated() {
      "frames=\{decoder.frame_count()} plays=\{decoder.plays()}"
    } else {
      "still"
    })
  let parts = [head]
  for frame in frames {
    let (fields, width, height, rows) = frame
    let d : Decoded = {
      rows,
      width,
      height,
      bit_depth: decoder.bit_depth(),
      color_type: decoder.color_type(),
      interlaced: decoder.interlaced(),
      palette: Bytes::from_array(decoder.palette()),
      fields: [],
      blocks: [],
      output: rows,
      transparency: None,
    }
    parts.push("\{fields} \{@codec_harness.sha256(pypng_shape(d, samples(d)))}")
  }
  parts.join("; ")
}

///|
test "APNG: the reference is the png crate, and every image is there" {
  inspect(apng_reference, content="png 0.18.1")
  inspect(apng_vectors.length(), content="45")
}

///|
test "APNG: every frame is the png crate's, its place and timing too" {
  for v in apng_vectors {
    let (decoder, frames) = decode_frames(v.input())
    let got = describe_frames(decoder, frames)
    let expected = as_applied(v.reference)
    if got != expected {
      fail("\{v.name}:\n ours  \{got}\n theirs \{expected}")
    }
  }
}

///|
test "APNG: with animation=false, the default image alone" {
  for v in apng_vectors {
    let (decoder, frames) = decode_frames(v.input(), animation=false)
    inspect(frames.length(), content="1")
    assert_false(decoder.animated())
    // The reference's first frame is the default image.
    let first = v.reference.split("; ").to_array()[1]
    let digest = first.split(" ").to_array()
    let ours = describe_frames(decoder, frames).split("; ").to_array()[1]
    assert_true(ours.has_suffix(digest[digest.length() - 1].to_owned()))
  }
}

///|
test "APNG: every image under the harness's checks" {
  for i, v in apng_vectors {
    let input = v.input()
    let (decoder, _) = decode_frames(input) catch {
      @codec_image.CodecError::CodecError(kind, message) =>
        fail("\{v.name}: \{@debug.to_string(kind)} \{message}")
      e => fail("\{v.name}: \{e}")
    }
    let bits = channels(decoder.color_type()) * decoder.bit_depth()
    let memory_limit = Some(
      47_360 +
      46_592 +
      2 * (1 + packed_bytes(decoder.width(), bits)) +
      input.length(),
    )
    let label = v.name
    let whole = @codec_harness.check_splits(
      () => png_stepper(),
      input,
      memory_limit~,
    ) catch {
      e => fail("\{label}: \{e}")
    }
    @codec_harness.check_truncation(
      () => png_stepper(),
      input,
      whole,
      max_prefixes=32,
    ) catch {
      e => fail("\{label}: \{e}")
    }
    @codec_harness.check_trailing(() => png_stepper(), input, whole, garbage=[
      b"x",
    ]) catch {
      e => fail("\{label}: \{e}")
    }
    let next = apng_vectors[(i + 1) % apng_vectors.length()].input()
    @codec_harness.check_member(
      () => png_stepper(until=EndOfMember),
      input,
      next,
      whole,
    ) catch {
      e => fail("\{label} until=EndOfMember: \{e}")
    }
    @codec_harness.check_reset(() => png_stepper(), next, input) catch {
      e => fail("\{label}: \{e}")
    }
    let _ = @codec_harness.check_error_splits(
      () => png_stepper(),
      input[:input.length() * 2 / 3],
      seed=i.reinterpret_as_uint(),
      memory_limit~,
    ) catch {
      e => fail("\{label} cut: \{e}")
    }
  }
}

///|
/// CRC-32 (ISO 3309) of `data`, bit by bit.
fn crc_of(data : Bytes) -> UInt32 {
  let mut c = 0xFFFFFFFFU
  for byte in data {
    c = c ^ byte.to_uint()
    for _ in 0..<8 {
      c = if (c & 1) != 0 { 0xEDB88320U ^ (c >> 1) } else { c >> 1 }
    }
  }
  c ^ 0xFFFFFFFFU
}

///|
fn put32(out : Buffer, n : UInt32) -> Unit {
  out.write_byte((n >> 24).to_byte())
  out.write_byte((n >> 16).to_byte())
  out.write_byte((n >> 8).to_byte())
  out.write_byte(n.to_byte())
}

///|
fn put_chunk(out : Buffer, name : String, data : Bytes) -> Unit {
  let body = Buffer()
  for c in name {
    body.write_byte(c.to_int().to_byte())
  }
  body.write_bytes(data)
  put32(out, data.length().reinterpret_as_uint())
  out.write_bytes(body.to_bytes())
  put32(out, crc_of(body.to_bytes()))
}

///|
/// The zlib stream of rows of a `w` x `h` 8-bit RGB frame, unfiltered, in
/// Adam7's passes.
fn interlaced_data(w : Int32, h : Int32, seed : Int32) -> Bytes {
  let raw = Buffer()
  let lattices = [
    (0, 0, 8, 8),
    (4, 0, 8, 8),
    (0, 4, 4, 8),
    (2, 0, 4, 4),
    (0, 2, 2, 4),
    (1, 0, 2, 2),
    (0, 1, 1, 2),
  ]
  for lattice in lattices {
    let (x0, y0, dx, dy) = lattice
    if x0 >= w || y0 >= h {
      continue
    }
    let columns = (w - x0 + dx - 1) / dx
    for y = y0; y < h; y = y + dy {
      raw.write_byte(b'\x00')
      for i in 0..<(columns * 3) {
        raw.write_byte((i * 7 + y * 13 + seed).to_byte())
      }
    }
  }
  @zlib.compress(raw.to_bytes())
}

///|
/// An interlaced 8 x 6 APNG: the default image as its first frame, then a
/// 5 x 5 and a 3 x 2 frame, the last fdAT data `cut` to its first half when
/// asked.
fn interlaced_apng(cut~ : Bool = false) -> Bytes {
  let out = Buffer()
  out.write_bytes(b"\x89PNG\r\n\x1a\n")
  let header = Buffer()
  put32(header, 8)
  put32(header, 6)
  header.write_bytes(b"\x08\x02\x00\x00\x01")
  put_chunk(out, "IHDR", header.to_bytes())
  let actl = Buffer()
  put32(actl, 3)
  put32(actl, 0)
  put_chunk(out, "acTL", actl.to_bytes())
  let mut sequence = 0U
  let fctl = (w : Int32, h : Int32, x : Int32, y : Int32) => {
    let f = Buffer()
    put32(f, sequence)
    for v in [w, h, x, y] {
      put32(f, v.reinterpret_as_uint())
    }
    f.write_bytes(b"\x00\x01\x00\x0a\x00\x00")
    put_chunk(out, "fcTL", f.to_bytes())
    sequence += 1
  }
  fctl(8, 6, 0, 0)
  put_chunk(out, "IDAT", interlaced_data(8, 6, 1))
  for frame in [(5, 5, 2, 1, 2), (3, 2, 4, 3, 3)] {
    let (w, h, x, y, seed) = frame
    fctl(w, h, x, y)
    let data = interlaced_data(w, h, seed)
    let data = if cut && seed == 3 {
      data[:data.length() / 2].to_owned()
    } else {
      data
    }
    // Two fdAT chunks a frame.
    let half = data.length() / 2
    for piece in [data[:half], data[half:]] {
      let f = Buffer()
      put32(f, sequence)
      f.write_bytes(piece.to_owned())
      put_chunk(out, "fdAT", f.to_bytes())
      sequence += 1
    }
  }
  put_chunk(out, "IEND", b"")
  out.to_bytes()
}

///|
test "APNG: interlaced frames, and a frame whose zlib stream is cut, under the harness's checks" {
  let input = interlaced_apng()
  let memory_limit = Some(47_360 + 46_592 + 2 * (1 + 24) + input.length())
  let whole = @codec_harness.check_splits(
    () => png_stepper(),
    input,
    memory_limit~,
  )
  inspect(
    whole.events.join("\n"),
    content=(
      #|header 8x6 Truecolor 8 interlaced
      #|frame 0,0 8x6
      #|pass 0 at 0,0 by 8,8
      #|pass 1 at 4,0 by 8,8
      #|pass 2 at 0,4 by 4,8
      #|pass 3 at 2,0 by 4,4
      #|pass 4 at 0,2 by 2,4
      #|pass 5 at 1,0 by 2,2
      #|pass 6 at 0,1 by 1,2
      #|frame end
      #|frame 2,1 5x5
      #|pass 0 at 0,0 by 8,8
      #|pass 1 at 4,0 by 8,8
      #|pass 2 at 0,4 by 4,8
      #|pass 3 at 2,0 by 4,4
      #|pass 4 at 0,2 by 2,4
      #|pass 5 at 1,0 by 2,2
      #|pass 6 at 0,1 by 1,2
      #|frame end
      #|frame 4,3 3x2
      #|pass 0 at 0,0 by 8,8
      #|pass 3 at 2,0 by 4,4
      #|pass 5 at 1,0 by 2,2
      #|pass 6 at 0,1 by 1,2
      #|frame end
    ),
  )
  @codec_harness.check_truncation(() => png_stepper(), input, whole)
  @codec_harness.check_trailing(() => png_stepper(), input, whole, garbage=[
    b"x",
  ])
  @codec_harness.check_member(
    () => png_stepper(until=EndOfMember),
    input,
    interlaced_apng(),
    whole,
  )
  @codec_harness.check_reset(
    () => png_stepper(),
    interlaced_apng(cut=true),
    input,
  )
  let _ = @codec_harness.fuzz(
    () => png_stepper(),
    input,
    seed=5,
    rounds=40,
    memory_limit~,
  )
  // The last frame's stream cut: the same rows, then Corrupt, however split.
  let cut = @codec_harness.check_error_splits(
    () => png_stepper(),
    interlaced_apng(cut=true),
    seed=9,
    memory_limit~,
  )
  debug_inspect(cut.error, content="Some(Corrupt)")
  inspect(cut.events.length() < whole.events.length(), content="true")
}
