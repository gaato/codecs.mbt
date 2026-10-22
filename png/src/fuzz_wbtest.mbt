///|
/// `input` with one seeded edit: a bit flipped, a byte replaced, inserted
/// or deleted, or the tail cut.
fn mutate(noise : Noise, input : Bytes) -> Bytes {
  let bytes = input.to_array()
  let at = noise.byte().to_int() * 256 + noise.byte().to_int()
  let at = at % bytes.length()
  match noise.byte().to_int() % 5 {
    0 => bytes[at] = bytes[at] ^ (1 << (noise.byte().to_int() % 8)).to_byte()
    1 => bytes[at] = noise.byte()
    2 => bytes.insert(at, noise.byte())
    3 => ignore(bytes.remove(at))
    _ => bytes.truncate(at)
  }
  Bytes::from_array(bytes)
}

///|
/// Images whose chunks are whole, with right CRCs, around image data with
/// one edit: the edits reach the zlib decoder and the filters.
fn edited_data(
  noise : Noise,
  width : Int32,
  height : Int32,
  bit_depth : Int32,
  color_type : Int32,
  interlaced : Bool,
) -> Bytes {
  let bits = @rules.channels(color_type) * bit_depth
  let raw = raw_image(width, height, bits, interlaced~)
  let data = if noise.byte().to_int() % 2 == 0 {
    mutate(noise, @zlib.compress(raw.filtered))
  } else {
    @zlib.compress(mutate(noise, raw.filtered))
  }
  let chunks = [
    chunk(
      "IHDR",
      ihdr_data(
        width.reinterpret_as_uint(),
        height.reinterpret_as_uint(),
        bit_depth,
        color_type,
        interlace=if interlaced { 1 } else { 0 },
      ),
    ),
  ]
  if color_type == 3 {
    chunks.push(chunk("PLTE", Bytes::makei(3 << bit_depth, i => i.to_byte())))
  }
  chunks.append(idat_chunks(data, 23))
  chunks.push(chunk("IEND", b""))
  png_of(chunks)
}

///|
test "corrupted images raise errors or decode, the same under every split, within bounds" {
  let noise = Noise::{ state: 7, }
  let sources = [
    image(9, 7, 8, 2).0,
    image(9, 7, 1, 0, interlaced=true).0,
    image(5, 11, 4, 3, idat_size=17).0,
    image(6, 6, 16, 6, interlaced=true, idat_size=40).0,
  ]
  let outcomes : Map[String, Int32] = Map([])
  for round in 0..<600 {
    let input = match round % 3 {
      0 => mutate(noise, sources[round / 3 % sources.length()])
      1 => edited_data(noise, 9, 7, 8, 2, false)
      _ => edited_data(noise, 6, 6, 16, 6, true)
    }
    let whole = run(Decoder(), input)
    for split in [(1, 1), (3, 5), (64, 7)] {
      let again = run(Decoder(), input, chunk=split.0, room=split.1)
      if again.output != whole.output ||
        again.error.map(e => e.0) != whole.error.map(e => e.0) {
        fail("round \{round}, split \{split.0}/\{split.1}: another outcome")
      }
    }
    // Every row the image can have is at most 6 pixels of 64 bits wide,
    // unless the edit made IHDR say otherwise, which the CRC catches.
    if whole.peak_memory > BASE_MEMORY + 2 * (1 + 48) {
      fail("round \{round}: memory \{whole.peak_memory}")
    }
    let name = match whole.error {
      None => "decoded"
      Some((kind, _)) => @debug.to_string(kind)
    }
    outcomes.set(name, outcomes.get_or_default(name, 0) + 1)
  }
  // Each kind of outcome happens.
  for
    name in [
      "decoded", "Corrupt", "ChecksumMismatch", "Truncated", "Unsupported",
    ] {
    assert_true(outcomes.contains(name))
  }
}
