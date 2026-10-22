///|
/// What a decoder holds before it knows the image: the zlib decoder and the
/// palette.
const BASE_MEMORY : Int32 = 46_592 + 768

///|
test "memory: the zlib decoder, the palette, and two rows from the step after Header" {
  let decoder = Decoder()
  inspect(decoder.memory_usage(), content="47360")
  let (png, _) = image(100, 7, 16, 6, interlaced=true)
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = png[:]
  debug_inspect(decoder.step(rest, out.mut_view(), end=true), content="Header")
  // Nothing is allocated for the image until the step after Header.
  inspect(decoder.memory_usage(), content="47360")
  rest = rest[decoder.last_consumed():]
  debug_inspect(decoder.step(rest, out.mut_view(), end=true), content="Frame")
  // Rows of 100 pixels of 64 bits: 800 bytes, and the filter type byte.
  assert_eq(decoder.memory_usage(), BASE_MEMORY + 2 * (1 + 800))
  decoder.reset()
  assert_eq(decoder.memory_usage(), BASE_MEMORY)
}

///|
test "memory stays what the formula says after every step, for every format and split" {
  for format in formats {
    let (color_type, bit_depth) = format
    for interlaced in [false, true] {
      let width = 37
      let (png, _) = image(width, 9, bit_depth, color_type, interlaced~)
      let bytes = @rules.pass_row_bytes(
        width,
        @rules.channels(color_type) * bit_depth,
      )
      for split in [(1, 1), (1 << 20, 1 << 16)] {
        let decoded = run(Decoder(), png, chunk=split.0, room=split.1)
        assert_true(decoded.error is None)
        assert_eq(decoded.peak_memory, BASE_MEMORY + 2 * (1 + bytes))
      }
    }
  }
}

///|
/// The limit a decoder made with `max_row_bytes` raises over an image of
/// `width` pixels of `bit_depth` and `color_type`, and the answers before
/// it.
fn limit_over(
  width : UInt32,
  bit_depth : Int32,
  color_type : Int32,
  max_row_bytes? : Int32,
) -> (String, @codec.Limit?) raise {
  let decoder = match max_row_bytes {
    Some(max_row_bytes) => Decoder(max_row_bytes~)
    None => Decoder()
  }
  let png = png_of([chunk("IHDR", ihdr_data(width, 1, bit_depth, color_type))])
  let out = FixedArray::make(16, b'\x00')
  let first = decoder.step(png, out.mut_view(), end=true) catch {
    _ => return ("raised at IHDR", None)
  }
  let rest = png[decoder.last_consumed():]
  let limit = try decoder.step(rest, out.mut_view(), end=true) catch {
    CodecError(LimitExceeded(limit), _) => Some(limit)
    _ => None
  } noraise {
    _ => None
  }
  inspect(decoder.memory_usage(), content="47360")
  (@debug.to_string(first), limit)
}

///|
test "max_row_bytes: a longer row is refused after Header, before anything is allocated" {
  // 100 pixels of 16-bit RGBA, against a limit one byte short.
  let (first, limit) = limit_over(100, 16, 6, max_row_bytes=799)
  inspect(first, content="Header")
  debug_inspect(
    limit,
    content="Some({ resource: Memory, needed: Some(800), limit: 799 })",
  )
  // The default: a million pixels of 16-bit RGBA, and not one more.
  let (_, limit) = limit_over(1_000_001, 16, 6)
  debug_inspect(
    limit,
    content="Some({ resource: Memory, needed: Some(8000008), limit: 8000000 })",
  )
  // The widest image there can be, whose rows take more than 2^34 bytes.
  let (_, limit) = limit_over(0x7FFFFFFF, 16, 6)
  debug_inspect(
    limit,
    content="Some({ resource: Memory, needed: Some(17179869176), limit: 8000000 })",
  )
  // A limit is at most 1,000,000,000 bytes.
  let (_, limit) = limit_over(0x7FFFFFFF, 8, 0, max_row_bytes=0x7FFFFFFF)
  debug_inspect(
    limit,
    content="Some({ resource: Memory, needed: Some(2147483647), limit: 1000000000 })",
  )
  // Within the limit, the rows are allocated.
  let decoder = Decoder(max_row_bytes=800)
  let (png, raw) = image(100, 2, 16, 6)
  let decoded = run(decoder, png)
  assert_true(decoded.error is None)
  assert_eq(decoded.output, raw.rows)
}

///|
test "output slices: whole rows, at most the slice, whatever it is given" {
  let (png, raw) = image(29, 13, 2, 3, interlaced=true)
  for room in [1, 2, 7, 8, 9, 100] {
    for chunk in [1, 13] {
      // `run` checks each step's counts against its slice.
      let decoded = run(Decoder(), png, chunk~, room~)
      assert_eq(decoded.output, raw.rows)
    }
  }
}
