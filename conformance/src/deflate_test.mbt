///|
/// What gaato/deflate documents for a raw DEFLATE decoder, with a dictionary
/// or without: the 32 KiB window, the inflater's second-level Huffman tables
/// and the bytes it keeps for a unit cut short.
let deflate_memory : Int32 = 74240

///|
/// The one gap in rule 4 that gaato/deflate documents (its README, known
/// limits): moonbit-community/flate 0.9.0 does not say what a step that
/// raises consumed and wrote, so a `Corrupt` that the inflater finds inside
/// the DEFLATE data comes without the output its step wrote, and the output
/// before it depends on the split. These are the inflater's messages for
/// those errors, as gaato/deflate passes them on (without "corrupt: "); every
/// other error, the framing's included, must give the same output under
/// every split.
let flate_corrupt_messages : Array[String] = [
  "bad Huffman code", "bad code-length symbol", "bad code-length tree", "bad distance tree",
  "bad literal/length tree", "code-length repeat overflow", "distance too far back",
  "invalid distance code", "invalid literal/length code", "repeat with no previous length",
  "reserved block type", "stored block length mismatch", "too many distance codes",
  "too many literal codes", "unexpected decoder error",
]

///|
/// Whether a run ended with one of the inflater's own `Corrupt` errors.
fn flate_corrupt(run : @codec_harness.Transcript) -> Bool {
  run.error is Some(Corrupt) && flate_corrupt_messages.contains(run.message)
}

///|
test "raw DEFLATE keeps the byte-stream contract" {
  // Nothing may follow the final block.
  conform(
    "deflate",
    deflate_vectors,
    (_, until) => @deflate.Decoder(until~),
    memory_limit=_ => deflate_memory,
    one_member=_ => true,
    garbage=[b"\x00", b"\xff\xff\xff\xff", b"\x1f\x8b\x08\x00"],
    short_output=flate_corrupt,
  )
}

///|
test "zlib keeps the byte-stream contract" {
  conform(
    "zlib",
    zlib_vectors,
    (_, until) => @zlib.Decoder(until~),
    memory_limit=_ => deflate_memory,
    one_member=_ => true,
    garbage=[b"\x00", b"\x78\x9c\x03\x00\x00\x00\x00\x01", b"\xff\xff"],
    short_output=flate_corrupt,
  )
}

///|
test "gzip keeps the byte-stream contract" {
  // Zero padding and bytes that are not the magic number are trailing; a
  // magic number would begin another member.
  conform(
    "gzip",
    gzip_vectors,
    (_, until) => @gzip.Decoder(until~),
    memory_limit=_ => deflate_memory + 65536,
    one_member=v => {
      !v.name.contains("members") && !v.name.contains("member_between")
    },
    garbage=[b"\x00\x00\x00\x00", b"\xff\xff\xff\xff", b"\x1f\x8c\x08\x00"],
    short_output=flate_corrupt,
  )
}

///|
test "corrupted DEFLATE, zlib and gzip streams never break the contract" {
  for v in deflate_vectors[:6] {
    let codec = () => @codec_harness.ByteDecoder::new(@deflate.Decoder())
    let _ = @codec_harness.fuzz(
      codec,
      v.input(),
      seed=1951,
      rounds=300,
      memory_limit=Some(deflate_memory),
      short_output=flate_corrupt,
    )
  }
  for v in zlib_vectors[:6] {
    let codec = () => @codec_harness.ByteDecoder::new(@zlib.Decoder())
    let _ = @codec_harness.fuzz(
      codec,
      v.input(),
      seed=1950,
      rounds=300,
      memory_limit=Some(deflate_memory),
      short_output=flate_corrupt,
    )
  }
  for v in gzip_vectors[:12] {
    let codec = () => @codec_harness.ByteDecoder::new(@gzip.Decoder())
    let _ = @codec_harness.fuzz(
      codec,
      v.input(),
      seed=1952,
      rounds=300,
      memory_limit=Some(deflate_memory + 65536),
      short_output=flate_corrupt,
    )
  }
}

///|
test "zlib-stream as Discord sends it: each message comes out whole, without end" {
  let stream = @base64.decode(zlib_flushed.compressed, ignore_whitespace=true)
  for chunk in [1, 13, 1 << 20] {
    let decoder = @zlib.Decoder()
    let out = FixedArray::make(97, b'\x00')
    let mut from = 0
    for message in zlib_flushed.messages {
      let (end, size, sha256) = message
      let text = Buffer()
      // The message arrives in chunks, through the contract alone.
      let mut pos = from
      while pos < end {
        let next = (pos + chunk).min(end)
        let mut rest = stream[pos:next]
        for ;; {
          let status = @codec_bytes.Decode::step(
            decoder,
            rest,
            out.mut_view(),
            end=false,
          )
          rest = rest[@codec_bytes.Decode::last_consumed(decoder):]
          let produced = @codec_bytes.Decode::last_produced(decoder)
          text.write_bytes(Bytes::from_array(out[:produced]))
          match status {
            NeedMoreInput => break
            NeedMoreOutput => ()
            Done => fail("the stream ended")
          }
        }
        pos = next
      }
      // After the message's last byte: everything consumed, everything out.
      assert_eq(text.length(), size, msg=zlib_flushed.name)
      assert_eq(@codec_harness.sha256(text.to_bytes()), sha256)
      from = end
    }
  }
}
