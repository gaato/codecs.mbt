// The expectations of the Web Platform Tests for the Compression Streams
// standard (web-platform-tests/wpt, compression/, BSD-3-Clause; see NOTICE),
// run on this repository's decoders with the standard's meaning: one stream,
// or one gzip member, and an error for anything after it.

///|
/// "expected output", as each WPT format compresses it
/// (resources/decompression-input.js).
let wpt_inputs : Map[String, Bytes] = {
  "deflate": [
    120, 156, 75, 173, 40, 72, 77, 46, 73, 77, 81, 200, 47, 45, 41, 40, 45, 1, 0,
    48, 173, 6, 36,
  ],
  "gzip": [
    31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 75, 173, 40, 72, 77, 46, 73, 77, 81, 200, 47,
    45, 41, 40, 45, 1, 0, 176, 1, 57, 179, 15, 0, 0, 0,
  ],
  "deflate-raw": [
    0x4b, 0xad, 0x28, 0x48, 0x4d, 0x2e, 0x49, 0x4d, 0x51, 0xc8, 0x2f, 0x2d, 0x29,
    0x28, 0x2d, 0x01, 0x00,
  ],
  "brotli": [
    0x21, 0x38, 0x00, 0x04, 0x65, 0x78, 0x70, 0x65, 0x63, 0x74, 0x65, 0x64, 0x20,
    0x6F, 0x75, 0x74, 0x70, 0x75, 0x74, 0x03,
  ],
}

///|
/// A decoder for a WPT format name, with the standard's end: gzip stops after
/// one member, so that what follows can be refused.
fn wpt_decoder(format : String) -> &@codec_bytes.Decode {
  match format {
    "deflate" => @zlib.Decoder() as &@codec_bytes.Decode
    "gzip" => @gzip.Decoder(until=EndOfMember) as &@codec_bytes.Decode
    "deflate-raw" => @deflate.Decoder() as &@codec_bytes.Decode
    _ => @brotli.Decoder() as &@codec_bytes.Decode
  }
}

///|
/// What DecompressionStream gives for `input`, as the WPT names it, and the
/// output that came before an error. The input arrives a byte at a time, so
/// that output the stream determines comes out before an error after it.
fn wpt_decompress(format : String, input : Bytes) -> (String, Bytes) raise {
  let run = @codec_harness.drive(
    @codec_harness.ByteDecoder::new(wpt_decoder(format)),
    input,
    input_sizes=@codec_harness.Sizes::fixed(1),
    first_member=true,
  )
  let result = if run.error is Some(_) || run.consumed != input.length() {
    "error"
  } else if run.output == b"expected output" {
    "success"
  } else {
    "corrupt"
  }
  (result, run.output)
}

///|
/// `input` with `length` bytes from `offset` (from the end when negative) set
/// to `value`, as the WPT's corruptInput does.
fn wpt_corrupt(
  input : Bytes,
  offset : Int32,
  length : Int32,
  value : Int32,
) -> Bytes {
  let bytes = input.to_array()
  let start = if offset < 0 { offset + bytes.length() } else { offset }
  for i in start..<(start + length) {
    bytes[i] = value.to_byte()
  }
  Bytes::from_array(bytes)
}

///|
test "decompression-corrupt-input: one field at a time" {
  // format, field, offset, length, value, result
  let cases : Array[(String, String, Int32, Int32, Int32, String)] = [
    ("deflate", "CMF", 0, 1, 0, "error"),
    ("deflate", "FLG", 1, 1, 218, "success"),
    ("deflate", "FLG", 1, 1, 1, "success"),
    ("deflate", "FLG", 1, 1, 94, "success"),
    ("deflate", "FLG", 1, 1, 157, "error"),
    ("deflate", "DATA", 18, 1, 4, "success"),
    ("deflate", "DATA", 18, 1, 5, "error"),
    ("deflate", "ADLER", -4, 4, 255, "error"),
    ("gzip", "ID", 0, 2, 255, "error"),
    ("gzip", "CM", 2, 1, 0, "error"),
    ("gzip", "FLG", 3, 1, 1, "success"),
    ("gzip", "FLG", 3, 1, 2, "error"),
    ("gzip", "MTIME", 4, 4, 255, "success"),
    ("gzip", "XFL", 8, 1, 255, "success"),
    ("gzip", "OS", 9, 1, 128, "success"),
    ("gzip", "DATA", 26, 1, 3, "error"),
    ("gzip", "DATA", 26, 1, 4, "success"),
    ("gzip", "CRC", -8, 4, 0, "error"),
    ("gzip", "ISIZE", -4, 4, 1, "error"),
  ]
  for c in cases {
    let (format, field, offset, length, value, expected) = c
    let input = wpt_corrupt(wpt_inputs[format], offset, length, value)
    let (result, _) = wpt_decompress(format, input)
    assert_eq(result, expected, msg="\{format} \{field} = \{value}")
  }
  // Each format unchanged, cut by a byte, and followed by a zero byte.
  for format in ["deflate", "gzip", "brotli"] {
    let input = wpt_inputs[format]
    assert_eq(wpt_decompress(format, input).0, "success", msg=format)
    let cut = input[:input.length() - 1].to_owned()
    assert_eq(wpt_decompress(format, cut).0, "error", msg=format)
    let junk = Bytes::from_array([..input, 0])
    assert_eq(wpt_decompress(format, junk).0, "error", msg=format)
  }
  // Compressed with a preset dictionary, decoded without.
  let with_dictionary : Bytes = [
    0x78, 0xbb, 0x74, 0xee, 0x09, 0x59, 0x2b, 0xc1, 0x2e, 0x0c, 0x00, 0x74, 0xee,
    0x09, 0x59,
  ]
  assert_eq(wpt_decompress("deflate", with_dictionary).0, "error")
}

///|
test "decompression-extra-input: the output, then an error" {
  for format in ["deflate", "gzip", "deflate-raw", "brotli"] {
    let input = Bytes::from_array([..wpt_inputs[format], 0])
    let (result, output) = wpt_decompress(format, input)
    assert_eq(result, "error", msg=format)
    assert_eq(output, b"expected output", msg=format)
  }
}

///|
test "decompression-empty-input: an empty stream decodes to nothing" {
  let empty : Array[(String, Bytes)] = [
    ("gzip", [31, 139, 8, 0, 0, 0, 0, 0, 0, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ("deflate", [120, 156, 3, 0, 0, 0, 0, 1]),
    ("deflate-raw", [1, 0, 0, 255, 255]),
    ("brotli", [0xa1, 0x01]),
  ]
  for e in empty {
    let (format, input) = e
    let run = @codec_harness.drive(
      @codec_harness.ByteDecoder::new(wpt_decoder(format)),
      input,
      first_member=true,
    )
    assert_true(run.error is None && run.output.length() == 0, msg=format)
    assert_eq(run.consumed, input.length(), msg=format)
  }
}

///|
test "decompression-brotli-large-window: refused, as RFC 7932 has no large window" {
  // "Hello World" with large_window and lgwin 25, an extension of RFC 9841
  // (Shared Brotli) that gaato/brotli does not implement. The WPT expects
  // browsers to decode it.
  let large_window : Bytes = [
    17, 25, 20, 0, 2, 72, 101, 108, 108, 111, 32, 87, 111, 114, 108, 100, 3,
  ]
  let run = @codec_harness.drive(
    @codec_harness.ByteDecoder::new(@brotli.Decoder()),
    large_window,
  )
  debug_inspect(
    run.error,
    content=(
      #|Some(Corrupt)
    ),
  )
}
