///|
/// `n` bytes of `bytes` from `at` as a little-endian number, written with
/// multiplication rather than shifts.
fn le_ref(bytes : Array[Int32], at : Int32, n : Int32) -> UInt64 {
  let mut value = 0UL
  let mut scale = 1UL
  for i in 0..<n {
    value = value + bytes[at + i].to_uint64() * scale
    scale = scale * 256
  }
  value
}

///|
/// `2^n` by repeated doubling.
fn pow2(n : Int32) -> UInt64 {
  let mut p = 1UL
  for _ in 0..<n {
    p = p * 2
  }
  p
}

///|
/// The frame header as RFC 8878 section 3.1.1.1 describes it, field by
/// field, from `bytes` (which hold at least the header).
fn frame_header_ref(
  bytes : Array[Int32],
) -> Result[@header.FrameHeader, String] {
  let descriptor = bytes[0]
  let frame_content_size_flag = descriptor / 64
  let single_segment = descriptor / 32 % 2 == 1
  let reserved = descriptor / 8 % 2 == 1
  let checksum = descriptor / 4 % 2 == 1
  let dictionary_id_flag = descriptor % 4
  if reserved {
    return Err("the frame header's reserved bit is set")
  }
  let did_field_size = [0, 1, 2, 4][dictionary_id_flag]
  let fcs_field_size = [if single_segment { 1 } else { 0 }, 2, 4, 8][frame_content_size_flag]
  let mut pos = 1
  let mut window = 0UL
  if !single_segment {
    let exponent = bytes[1] / 8
    let mantissa = bytes[1] % 8
    let window_base = pow2(10 + exponent)
    let window_add = window_base / 8 * mantissa.to_uint64()
    window = window_base + window_add
    pos = 2
  }
  let dictionary_id = le_ref(bytes, pos, did_field_size).to_uint()
  pos = pos + did_field_size
  let content_size = match fcs_field_size {
    0 => None
    2 => Some(le_ref(bytes, pos, 2) + 256)
    n => Some(le_ref(bytes, pos, n))
  }
  pos = pos + fcs_field_size
  if single_segment {
    window = content_size.unwrap()
  }
  Ok({
    single_segment,
    has_checksum: checksum,
    dictionary_id,
    content_size,
    window_size: window,
    header_len: pos,
  })
}

///|
fn to_bytes(values : Array[Int32]) -> Array[Byte] {
  values.map(v => v.to_byte())
}

///|
test "frame headers: every descriptor and window descriptor against the RFC" {
  for descriptor in 0..<256 {
    for window_byte in 0..<256 {
      // Field bytes that differ from field to field and from header to
      // header, with all-zero and all-one fields among them.
      let fill = match window_byte % 4 {
        0 => _ => 0
        1 => _ => 0xFF
        _ => i => (descriptor * 31 + window_byte * 7 + i * 13) % 256
      }
      let bytes = [descriptor, window_byte]
      for i in 2..<14 {
        bytes.push(fill(i))
      }
      let expected = frame_header_ref(bytes)
      let actual = @header.parse_frame_header(to_bytes(bytes)[:])
      if actual != expected {
        fail("descriptor \{descriptor}, window \{window_byte}: \{Repr(actual)}")
      }
      let len = @header.frame_header_len(descriptor)
      assert_eq(len, expected.map(h => h.header_len))
      // Only the header's own bytes count: a view of just the header, and
      // one cut shorter, read the missing bytes as zero.
      if len is Ok(len) {
        assert_eq(@header.parse_frame_header(to_bytes(bytes)[:len]), expected)
        let cut = len / 2
        let padded = [..bytes[:cut], ..Array::make(14 - cut, 0)]
        assert_eq(
          @header.parse_frame_header(to_bytes(bytes)[:cut]),
          frame_header_ref(padded),
        )
      }
    }
  }
}

///|
test "frame headers: lengths, windows and the extreme fields" {
  // Every header length from 2 to 14 bytes occurs.
  let lengths = []
  for descriptor in 0..<256 {
    if @header.frame_header_len(descriptor) is Ok(len) && !lengths.contains(len) {
      lengths.push(len)
    }
  }
  lengths.sort()
  debug_inspect(
    lengths,
    content=(
      #|[2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    ),
  )
  inspect(@header.window_size(0), content="1024")
  inspect(@header.window_size(1), content="1152")
  inspect(
    @header.window_size(0xFF),
    content=(
      #|4123168604160
    ),
  )
  assert_eq(@header.window_size(0xFF), pow2(41) + 7UL * pow2(38))
  // An empty view reads as a zero descriptor and fields.
  debug_inspect(
    @header.parse_frame_header([][:]),
    content=(
      #|Ok(
      #|  {
      #|    single_segment: false,
      #|    has_checksum: false,
      #|    dictionary_id: 0,
      #|    content_size: None,
      #|    window_size: 1024,
      #|    header_len: 2,
      #|  },
      #|)
    ),
  )
  // The largest fields: a 4-byte dictionary ID and an 8-byte content size.
  let header = @header.parse_frame_header(
    to_bytes([0xE3, ..Array::make(12, 0xFF)])[:],
  )
  debug_inspect(
    header,
    content=(
      #|Ok(
      #|  {
      #|    single_segment: true,
      #|    has_checksum: false,
      #|    dictionary_id: 4294967295,
      #|    content_size: Some(18446744073709551615),
      #|    window_size: 18446744073709551615,
      #|    header_len: 13,
      #|  },
      #|)
    ),
  )
}
