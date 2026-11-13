// The encoder against the decoder: round trips, splits, flushes, the
// content size, and the frames and blocks it chooses.

///|
/// Text-like bytes: words from a small vocabulary, seeded.
fn sample_text(rng : Rng, n : Int32) -> Bytes {
  let words = [
    "the ", "of ", "zstd ", "frame ", "window ", "and ", "block ", "a ", "to ", "literal ",
    "Huffman ", "stream ", "\n", "in ", "is ", "MoonBit ", "{\"key\": [1, 2, 3]} ",
  ]
  let out = Buffer()
  while out.length() < n {
    out.write_string_utf8(words[rng.below(words.length())])
  }
  out.to_bytes()[:n].to_owned()
}

///|
fn sample_random(rng : Rng, n : Int32) -> Bytes {
  // The high bits: the low ones of an LCG repeat soon.
  Bytes::makei(n, _ => (rng.below(1 << 16) >> 8).to_byte())
}

///|
/// Inputs for the encoder: edge cases, runs, random bytes, text, and sizes
/// at the block limit, the literals headers' size classes and the
/// parameter tables' size classes.
fn encoder_inputs() -> Array[(String, Bytes)] {
  let rng = Rng::new(8878)
  let inputs = [
    ("empty", b""),
    ("one byte", b"x"),
    ("two bytes", b"xy"),
    ("run", Bytes::make(1000, b'a')),
    ("long run", Bytes::make(300000, b'\x00')),
    ("random", sample_random(rng, 5000)),
    ("text", sample_text(rng, 20000)),
    (
      "two symbols",
      Bytes::makei(3000, i => if i % 3 == 0 { b'a' } else { b'b' }),
    ),
    (
      "mixed",
      sample_text(rng, 100000) +
      sample_random(rng, 40000) +
      Bytes::make(50000, b'z') +
      sample_text(rng, 60000),
    ),
  ]
  for
    n in [
      31, 32, 255, 256, 1023, 1024, 4095, 4096, 16383, 16384, 16385, 131071, 131072,
      131073, 262143, 262144, 262145,
    ] {
    inputs.push(("text \{n}", sample_text(rng, n)))
  }
  inputs
}

///|
/// Encodes `input` with `encoder`, `next_in()` input bytes per chunk into
/// buffers of `next_out()` bytes (a `FixedArray` through `step_into`, or a
/// view through `step`). A chunk ending at `flush(end)` ends with `Flush`,
/// after which `on_flush(end, output so far)` is called; the last chunk
/// ends with `Finish`. `check` runs after every step.
fn encode_drive(
  encoder : Encoder,
  input : BytesView,
  next_in~ : () -> Int32,
  next_out~ : () -> Int32,
  flush~ : (Int32) -> Bool = _ => false,
  fixed~ : Bool = true,
  check~ : (Encoder, Int32) -> Unit raise = (_, _) => (),
  on_flush~ : (Int32, Bytes) -> Unit raise = (_, _) => (),
) -> Bytes raise {
  let out = Buffer()
  let mut pos = 0
  let mut buffer = FixedArray::make(0, b'\x00')
  for ;; {
    let end = (pos + next_in()).min(input.length())
    let action : EncodeAction = if end == input.length() {
      Finish
    } else if flush(end) {
      Flush
    } else {
      Continue
    }
    let mut rest = input[pos:end]
    for ;; {
      let room = next_out()
      if buffer.length() != room {
        buffer = FixedArray::make(room, b'\x00')
      }
      let status = if fixed {
        encoder.step_into(rest, buffer, action~)
      } else {
        encoder.step(rest, buffer.mut_view(), action~)
      }
      check(encoder, room)
      assert_true(encoder.last_produced() <= room)
      rest = rest[encoder.last_consumed():]
      out.write_bytesview(
        Bytes::from_array(buffer[:encoder.last_produced()])[:],
      )
      match status {
        Done => {
          assert_eq(rest.length(), 0)
          assert_true(encoder.is_finished())
          return out.to_bytes()
        }
        NeedMoreInput => {
          assert_eq(rest.length(), 0)
          break
        }
        NeedMoreOutput =>
          if encoder.last_consumed() == 0 && encoder.last_produced() == 0 {
            fail("no progress")
          }
      }
    }
    if action is Flush {
      on_flush(end, out.to_bytes())
    }
    pos = end
  }
}

///|
/// Feeds `bytes` to `decoder` without telling it the stream has ended and
/// appends what it gives out to `out`.
fn decode_available(
  decoder : Decoder,
  bytes : BytesView,
  out : Buffer,
) -> Unit raise {
  let buffer = FixedArray::make(4096, b'\x00')
  let mut rest = bytes
  for ;; {
    let status = decoder.step_into(rest, buffer, end=false)
    rest = rest[decoder.last_consumed():]
    out.write_bytesview(Bytes::from_array(buffer[:decoder.last_produced()])[:])
    if status is (NeedMoreInput | Done) {
      return
    }
  }
}

///|
/// The header of the frame `stream` begins with.
fn frame_header_of(stream : BytesView) -> @header.FrameHeader {
  let bytes = Array::makei((stream.length() - 4).clamp(min=0, max=14), i => {
    stream[4 + i]
  })
  @header.parse_frame_header(bytes[:]).unwrap()
}

///|
/// A frame's blocks, walked by their headers: (Last_Block, Block_Type,
/// Block_Size, the bytes the block takes after its header), and the bytes
/// after the last block.
fn frame_blocks(
  stream : Bytes,
) -> (Array[(Bool, @header.BlockType, Int32, Int32)], Int32) {
  let fh = frame_header_of(stream)
  let mut pos = 4 + fh.header_len
  let blocks = []
  for ;; {
    let value = stream[pos].to_int() |
      (stream[pos + 1].to_int() << 8) |
      (stream[pos + 2].to_int() << 16)
    let h = @header.parse_block_header(value).unwrap()
    let taken = if h.block_type is Rle { 1 } else { h.size }
    blocks.push((h.last, h.block_type, h.size, taken))
    pos += 3 + taken
    if h.last {
      return (blocks, stream.length() - pos)
    }
  }
}

///|
test "compress round-trips through the decoder at every level" {
  for sample in encoder_inputs() {
    let (name, input) = sample
    for level in 1..<=12 {
      for checksum in [true, false] {
        let compressed = compress(input, level~, checksum~)
        let got = decompress(compressed)
        let label = "\{name} level \{level} checksum \{checksum}"
        assert_eq(got.length(), input.length(), msg=label)
        assert_true(got == input, msg=label)
        let fh = frame_header_of(compressed)
        assert_eq(fh.has_checksum, checksum, msg=label)
        assert_eq(fh.content_size, Some(input.length().to_uint64()), msg=label)
        let (_, after) = frame_blocks(compressed)
        assert_eq(after, if checksum { 4 } else { 0 }, msg=label)
      }
    }
  }
}

///|
test "any input split and output size give the same frame" {
  let splits : Array[(Int32, Int32)] = [
    (1, 1 << 16),
    (1 << 16, 1),
    (1, 1),
    (7, 3),
    (4096, 64),
    (131072, 131072),
    (131073, 100000),
  ]
  for sample in encoder_inputs() {
    let (name, input) = sample
    for sized in [false, true] {
      let encoder = () => {
        if sized {
          Encoder(content_size=input.length().to_int64())
        } else {
          Encoder()
        }
      }
      let whole = encode_drive(encoder(), input, next_in=() => 1 << 22, next_out=() => {
        1 << 22
      })
      assert_true(decompress(whole) == input, msg=name)
      if sized {
        // `compress` is the encoder told the content size.
        assert_true(whole == compress(input), msg=name)
      }
      for split in splits {
        let (in_chunk, out_chunk) = split
        if in_chunk * out_chunk < 64 && input.length() > 20000 {
          continue
        }
        let got = encode_drive(
          encoder(),
          input,
          next_in=() => in_chunk,
          next_out=() => out_chunk,
          fixed=in_chunk != 7,
        )
        assert_true(
          got == whole,
          msg="\{name} sized \{sized} in \{in_chunk} out \{out_chunk}",
        )
      }
    }
  }
}

///|
test "a flush makes the frame so far decode to the input so far" {
  let rng = Rng::new(1951)
  let mut flushes = 0
  for sample in encoder_inputs() {
    let (name, input) = sample
    for round in 0..<4 {
      let max_in = [1, 300, 70000, 70000][round]
      let max_out = [7, 5000, 1 << 17, 1 << 17][round]
      let every = [97, 1000, 1, 1][round]
      if round == 0 && input.length() > 50000 {
        continue
      }
      let decoder = Decoder()
      let decoded = Buffer()
      let mut fed = 0
      let stream = encode_drive(
        Encoder(level=[1, 3, 4, 12][round]),
        input,
        next_in=() => 1 + rng.below(max_in),
        next_out=() => 1 + rng.below(max_out),
        flush=_ => rng.below(every) == 0,
        fixed=round != 1,
        on_flush=(end, so_far) => {
          flushes += 1
          let checked = decoded.length()
          decode_available(decoder, so_far[fed:], decoded)
          fed = so_far.length()
          assert_eq(decoded.length(), end, msg="\{name} round \{round}")
          let view = decoded.view()
          for k in checked..<end {
            if view[k] != input[k] {
              fail("\{name} round \{round}: byte \{k} differs")
            }
          }
        },
      )
      assert_true(decompress(stream) == input, msg="\{name} round \{round}")
    }
  }
  assert_true(flushes > 100)
}

///|
test "blocks: raw, RLE or sequences, whichever is smallest, at most 128 KiB" {
  let rng = Rng::new(17)
  let summary = (input : Bytes) => {
    let (blocks, _) = frame_blocks(compress(input))
    let parts = blocks.map(b => {
      let (last, kind, size, taken) = b
      let kind = match kind {
        Raw => "raw"
        Rle => "rle"
        Compressed => "compressed"
      }
      "\{kind} \{size}/\{taken}\{if last { " last" } else { "" }}"
    })
    parts.join(", ")
  }
  inspect(summary(b""), content="raw 0/0 last")
  inspect(summary(b"x"), content="raw 1/1 last")
  inspect(summary(b"xx"), content="rle 2/1 last")
  inspect(
    summary(Bytes::make(300000, b'a')),
    content=(
      #|rle 131072/1, rle 131072/1, rle 37856/1 last
    ),
  )
  // Random bytes do not compress: raw.
  inspect(summary(sample_random(rng, 1000)), content="raw 1000/1000 last")
  // Text does, by about a third.
  inspect(
    summary(sample_text(rng, 1000)),
    content=(
      #|compressed 319/319 last
    ),
  )
  // A block ends at 128 KiB, and only there.
  inspect(
    summary(sample_text(rng, 262145)),
    content=(
      #|compressed 24976/24976, compressed 24565/24565, raw 1/1 last
    ),
  )
  // Few literals: Huffman costs more than it saves.
  inspect(
    summary(b"abcabcabcabc"),
    content=(
      #|raw 12/12 last
    ),
  )
}

///|
test "incompressible input costs 3 bytes a block and the frame's header and checksum" {
  let rng = Rng::new(16)
  for n in [0, 1, 1000, 131072, 131073, 300000] {
    let input = sample_random(rng, n)
    let compressed = compress(input)
    // Magic, descriptor, content size (4 bytes here), 3 bytes a block (an
    // empty one for no input), checksum.
    let blocks = (n + MAX_BLOCK_SIZE - 1) / MAX_BLOCK_SIZE
    assert_true(
      compressed.length() <= n + 4 + 1 + 4 + 3 * blocks.max(1) + 4,
      msg="\{n}",
    )
    assert_true(decompress(compressed) == input)
  }
}

///|
test "compress writes into one array, grown only when its bound is too small" {
  let rng = Rng::new(17)
  let input = sample_text(rng, 5000) + sample_random(rng, 3000)
  let expected = encode_drive(
    Encoder(content_size=input.length().to_int64()),
    input,
    next_in=() => 1 << 20,
    next_out=() => 1 << 20,
  )
  assert_true(compress(input) == expected)
  // Too small an array doubles until the frame fits, as many times as it
  // takes, and an exact fit needs no trimming copy.
  for capacity in [0, 1, 7, expected.length()] {
    let encoder = Encoder(content_size=input.length().to_int64())
    assert_true(
      encode_whole(encoder, input, capacity) == expected,
      msg="\{capacity}",
    )
  }
  // Incompressible input reaches the bound's raw blocks, and an empty
  // input its empty block.
  for n in [0, 131072, 300000] {
    let random = sample_random(rng, n)
    assert_true(decompress(compress(random)) == random, msg="\{n}")
  }
}

///|
test "frame headers: the window from the level, the content size when known" {
  let header = (stream : Bytes) => {
    let fh = frame_header_of(stream)
    let size = match fh.content_size {
      Some(size) => size.to_string()
      None => "none"
    }
    "single \{fh.single_segment}, window \{fh.window_size}, size \{size}, checksum \{fh.has_checksum}"
  }
  let stream = (encoder : Encoder, input : Bytes) => {
    encode_drive(encoder, input, next_in=() => 1 << 20, next_out=() => 1 << 20)
  }
  // Unknown size: the window of the table for large inputs, 512 KiB at
  // level 1, 1 MiB at level 2 and 2 MiB for the double-fast rows.
  let windows = [
    for level in [-5, 0, 1, 2, 3, 8, 9, 12, 13, 22] => {
      let fh = frame_header_of(stream(Encoder(level~), b"abc"))
      fh.window_size.to_string()
    }
  ]
  inspect(
    windows.join(" "),
    content=(
      #|524288 524288 524288 1048576 2097152 2097152 4194304 4194304 4194304 4194304
    ),
  )
  inspect(
    header(stream(Encoder(checksum=false), b"abc")),
    content=(
      #|single false, window 2097152, size none, checksum false
    ),
  )
  // Known size: single-segment, the window is the content.
  inspect(
    header(compress(b"")),
    content="single true, window 0, size 0, checksum true",
  )
  inspect(
    header(compress(Bytes::make(300000, b'a'))),
    content="single true, window 300000, size 300000, checksum true",
  )
  // Larger than the level's window: a window descriptor and the size.
  let big = Bytes::make(3000000, b'a')
  inspect(
    header(compress(big)),
    content=(
      #|single false, window 2097152, size 3000000, checksum true
    ),
  )
  inspect(
    header(compress(big, level=12)),
    content=(
      #|single true, window 3000000, size 3000000, checksum true
    ),
  )
  assert_true(decompress(compress(big)) == big)
}

///|
test "the parameters follow zstd's tables" {
  let show = (p : Params) => {
    let strategy = match p.strategy {
      Fast => "fast"
      Dfast => "dfast"
      Greedy => "greedy"
      Lazy => "lazy"
      Lazy2 => "lazy2"
      Btlazy2 => "btlazy2"
      Btopt => "btopt"
    }
    "\{p.window_log} \{p.chain_log} \{p.hash_log} \{p.search_log} \{p.min_match} \{p.target_length} \{strategy}"
  }
  // Spot checks against clevels.h, one row from each table.
  inspect(show(params_for(1, None)), content="19 13 14 1 7 0 fast")
  inspect(show(params_for(12, None)), content="22 22 23 6 5 32 lazy2")
  inspect(show(params_for(3, Some(200000))), content="18 16 16 1 4 0 dfast")
  inspect(show(params_for(11, Some(100000))), content="17 17 17 5 4 8 btlazy2")
  inspect(show(params_for(12, Some(10000))), content="14 15 14 4 3 24 btopt")
  // The window shrinks to the input, down to 1 KiB.
  let windows = [
    for
      size in [
        0L,
        63,
        64,
        1024,
        1025,
        16384,
        16385,
        131072,
        131073,
        262144,
        262145,
        1L << 30,
        (1L << 30) + 1,
      ] => params_for(3, Some(size)).window_log.to_string()
  ]
  inspect(windows.join(" "), content="10 10 10 10 11 14 15 17 18 18 19 21 21")
  // Every table has a row for each level, and each window is a window.
  for table in level_tables {
    assert_eq(table.length(), MAX_LEVEL)
    for p in table {
      assert_true(p.window_log >= 14 && p.window_log <= 22)
    }
  }
}

///|
test "steps after the end take no input" {
  let encoder = Encoder()
  let out = FixedArray::make(64, b'\x00')
  debug_inspect(
    encoder.step_into(b"hello", out, action=Continue),
    content="NeedMoreInput",
  )
  inspect(encoder.last_consumed(), content="5")
  inspect(encoder.last_produced(), content="0")
  inspect(encoder.is_finished(), content="false")
  debug_inspect(encoder.step_into(b"", out, action=Finish), content="Done")
  let stream = Bytes::from_array(out[:encoder.last_produced()])
  assert_true(decompress(stream) == b"hello")
  debug_inspect(encoder.step_into(b"more", out, action=Finish), content="Done")
  inspect(encoder.last_consumed(), content="0")
  inspect(encoder.last_produced(), content="0")
  // A reset encoder makes the same frame again.
  encoder.reset()
  inspect(encoder.is_finished(), content="false")
  debug_inspect(encoder.step_into(b"hello", out, action=Finish), content="Done")
  assert_true(Bytes::from_array(out[:encoder.last_produced()]) == stream)
}

///|
test "flushes with nothing new add nothing" {
  let encoder = Encoder()
  let out = FixedArray::make(64, b'\x00')
  // A flush before any input writes nothing, not even the frame header.
  debug_inspect(
    encoder.step_into(b"", out, action=Flush),
    content="NeedMoreInput",
  )
  inspect(encoder.last_produced(), content="0")
  debug_inspect(
    encoder.step_into(b"abc", out, action=Flush),
    content="NeedMoreInput",
  )
  // The frame header (magic, descriptor, window) and a raw block.
  inspect(encoder.last_produced(), content="12")
  debug_inspect(
    encoder.step_into(b"", out, action=Flush),
    content="NeedMoreInput",
  )
  inspect(encoder.last_produced(), content="0")
  // Output waits for room; the flush stays requested.
  debug_inspect(
    encoder.step_into(b"defg", FixedArray::make(0, b'\x00'), action=Flush),
    content="NeedMoreOutput",
  )
  inspect(encoder.last_consumed(), content="4")
  debug_inspect(
    encoder.step_into(b"", out, action=Continue),
    content="NeedMoreInput",
  )
  inspect(encoder.last_produced(), content="7")
  // Finish after a flush: an empty last block and the checksum.
  debug_inspect(encoder.step_into(b"", out, action=Finish), content="Done")
  inspect(encoder.last_produced(), content="7")
}

///|
test "a full block waits for the next byte to know whether it is the last" {
  let input = Bytes::make(MAX_BLOCK_SIZE, b'q')
  let encoder = Encoder(checksum=false)
  let out = FixedArray::make(64, b'\x00')
  debug_inspect(
    encoder.step_into(input, out, action=Continue),
    content="NeedMoreInput",
  )
  inspect(encoder.last_produced(), content="0")
  debug_inspect(encoder.step_into(b"", out, action=Finish), content="Done")
  // One RLE block, the last: no empty block after it.
  let stream = Bytes::from_array(out[:encoder.last_produced()])
  inspect(frame_blocks(stream).0.length(), content="1")
  // With one more byte, the full block goes out before it is taken.
  encoder.reset()
  debug_inspect(
    encoder.step_into(input + b"r", out, action=Continue),
    content="NeedMoreInput",
  )
  inspect(encoder.last_produced(), content="10")
}

///|
test "the input must match the content size given" {
  let out = FixedArray::make(64, b'\x00')
  let raised = (f : () -> Status raise @codec.CodecError) => {
    try f() catch {
      @codec.CodecError(kind, message) => "\{Repr(kind)}: \{message}"
    } noraise {
      _ => "no error"
    }
  }
  // Too long: the bytes up to the content size are taken, then it raises.
  let encoder = Encoder(content_size=5)
  debug_inspect(
    encoder.step_into(b"abc", out, action=Continue),
    content="NeedMoreInput",
  )
  inspect(
    raised(() => encoder.step_into(b"def", out, action=Continue)),
    content="ChecksumMismatch: the input is longer than the content size given, 5 bytes",
  )
  inspect(encoder.last_consumed(), content="2")
  // The error sticks, until reset.
  inspect(
    raised(() => encoder.step_into(b"", out, action=Finish)),
    content="ChecksumMismatch: the input is longer than the content size given, 5 bytes",
  )
  inspect(encoder.last_consumed(), content="0")
  inspect(encoder.last_produced(), content="0")
  encoder.reset()
  debug_inspect(encoder.step_into(b"abcde", out, action=Finish), content="Done")
  assert_true(
    decompress(Bytes::from_array(out[:encoder.last_produced()])) == b"abcde",
  )
  // Too short, found at Finish.
  let encoder = Encoder(content_size=200000)
  let input = Bytes::make(150000, b'x')
  let mut flushed = 0
  debug_inspect(
    encoder.step_into(input, FixedArray::make(1000, b'\x00'), action=Flush),
    content="NeedMoreInput",
  )
  flushed += encoder.last_produced()
  inspect(
    raised(() => encoder.step_into(b"", out, action=Finish)),
    content="ChecksumMismatch: the input ends at 150000 bytes, short of the content size given, 200000",
  )
  inspect(flushed > 0, content="true")
  // A negative content size counts as none.
  let encoder = Encoder(content_size=-1)
  debug_inspect(encoder.step_into(b"abc", out, action=Finish), content="Done")
  let fh = frame_header_of(Bytes::from_array(out[:encoder.last_produced()]))
  inspect(fh.content_size is None, content="true")
}

///|
test "the same encoder after reset writes the same frames" {
  let inputs = encoder_inputs()
  for level in 1..<=12 {
    let encoder = Encoder(level~)
    for sample in inputs {
      let (name, input) = sample
      encoder.reset()
      let got = encode_drive(encoder, input, next_in=() => 50000, next_out=() => {
        7000
      })
      let fresh = encode_drive(Encoder(level~), input, next_in=() => 50000, next_out=() => {
        7000
      })
      assert_true(got == fresh, msg="\{name} level \{level}")
    }
  }
}

///|
/// The SHA-256 of the encoder's frames for a fixed input at each level,
/// with and without the content size, and of one flushed every 10,000
/// bytes: the same on every target (the gates run the tests on all four),
/// and the same until a change means to alter the bytes the encoder writes.
test "every target writes the same bytes" {
  let rng = Rng::new(1951)
  let input = sample_text(rng, 150000) +
    sample_random(rng, 30000) +
    Bytes::make(70000, b'\x00') +
    sample_text(rng, 50000)
  let digests = []
  for level in 1..<=12 {
    digests.push(@checksum.sha256(compress(input, level~)))
    let stream = encode_drive(Encoder(level~), input, next_in=() => 1 << 20, next_out=() => {
      1 << 16
    })
    digests.push(@checksum.sha256(stream))
  }
  let flushed = encode_drive(
    Encoder(),
    input,
    next_in=() => 10000,
    next_out=() => 1 << 16,
    flush=_ => true,
  )
  digests.push(@checksum.sha256(flushed))
  inspect(
    digests.join("\n"),
    content=(
      #|61e3eab58e2eec4632a275433b78538f2c768e9b666cd5604a4c54a212037cb8
      #|0770bb9d029235955caab0fd7f2f1cefb24b4ce7edfd7f8b4387888578dd9183
      #|f18f3fd9d0b98b700e797a0270c17e3f33f1a1d106c75dc66138581bdb1ac401
      #|8fd8a3bd5db57442874e2a629e3d9118d21376eca8f088b9aab9ed8b9ba328fe
      #|9d4f9cf68ba54bd7b5bb9be86fdbc454a43ace8d0d249d43216bda1bb18a5733
      #|a5eecad5b3f5b444bea4726e76c9502dbc7bd8a07bb6773ecd06d1e79a9ae475
      #|2f30bdd49e97b38915bc17d9e3b92f5c39a1baaa90559546b298c7292453d5b2
      #|452997d3115fea248699edd64034d36fa191844e2906a9b73a308e533cf2ad9b
      #|f8dbd0ae19f8fa8edd0be32b2b2f1398d2a711f9a0b067dec8c0c45cd319bbdf
      #|3e644f5a21b039170ad96179b9071570dea78253854c52f7feae1f5e3e05898e
      #|c07ff459535469446d62add47d3bc695d2b260facec0c47508394da7150f98cc
      #|f69e9b439ffac9d25ba1d02deb2e1ab0fc6dc94c6e600c520003cd2359975c4a
      #|847fbbddb2e77fb7f681847f4337f59549f2ee87102590010a1c2e3cd6083bfa
      #|f31c9189eb3b45a4a69b4488d9287665381a31190a7e6f90df9b41b7e0baa72e
      #|59359795309946e9866b5dba43a3724369456d2e1c92eb7aeaeb61fbf54858c9
      #|0da1c7392ad3e6153ecb233741762c04ad1fc0b45437f86855ad9a40a5f4461b
      #|59359795309946e9866b5dba43a3724369456d2e1c92eb7aeaeb61fbf54858c9
      #|0091305f566926ae5b675bcd720cd6601016f144d5a27615aa9dc517da3acbec
      #|f727e95002bc7a65998e7a884d0604a60d9a277a9a044928f792f2f7a806b79a
      #|e83115e5c2bcb6982d0f9ec04474904f0d9063b4a7e213ae9197d2b3abb097da
      #|7edfd12e3725f570408696eb569290fb82584728e178274279d97c1a2a3db2c3
      #|05864ba530465274e7efe1cb5ddb7cc9312c2783056ff5437696dc3f45b88bce
      #|7edfd12e3725f570408696eb569290fb82584728e178274279d97c1a2a3db2c3
      #|05864ba530465274e7efe1cb5ddb7cc9312c2783056ff5437696dc3f45b88bce
      #|c273ce57ffa9f155fba91e1a4871e47c01aa674d82c8ec45167b767cbcc40f95
    ),
  )
}

///|
/// Everything an encoder given `content_size` writes, fed `input` in pieces
/// of `piece` bytes into outputs of `room` bytes, up to the error it raises
/// (or the end), and that error.
fn written_until_error(
  content_size : Int64,
  input : Bytes,
  piece : Int32,
  room : Int32,
) -> (Bytes, String) {
  let encoder = Encoder(content_size~)
  let out = FixedArray::make(room, b'\x00')
  let written = Buffer()
  let mut pos = 0
  for ;; {
    let end = (pos + piece).min(input.length())
    let action : EncodeAction = if end == input.length() {
      Finish
    } else {
      Continue
    }
    let status = encoder.step_into(input[pos:end], out, action~) catch {
      @codec.CodecError(kind, message) => {
        for i in 0..<encoder.last_produced() {
          written.write_byte(out[i])
        }
        return (written.to_bytes(), "\{Repr(kind)}: \{message}")
      }
    }
    for i in 0..<encoder.last_produced() {
      written.write_byte(out[i])
    }
    pos += encoder.last_consumed()
    if status is Done {
      return (written.to_bytes(), "no error")
    }
  }
}

///|
test "input past the content size raises after the same output, however it is split" {
  // 131,074 bytes declared as 131,073: the first block fills exactly at the
  // content size, so whether it is written before the error must not
  // depend on where the pieces end.
  let input = Bytes::make(131074, b'x')
  let (expected, error) = written_until_error(
    131073,
    input,
    input.length(),
    1 << 20,
  )
  inspect(
    error,
    content="ChecksumMismatch: the input is longer than the content size given, 131073 bytes",
  )
  for split in [(131073, 64), (1, 64), (65536, 7), (131074, 1), (4096, 1 << 20)] {
    let (piece, room) = split
    let (got, err) = written_until_error(131073, input, piece, room)
    assert_eq(err, error, msg="piece \{piece} room \{room}")
    assert_true(got == expected, msg="piece \{piece} room \{room}")
  }
  // A short declared size and text: the same.
  let text = Bytes::from_array(
    FixedArray::makei(300000, i => (i * 31 % 251).to_byte()),
  )
  let (expected, _) = written_until_error(200000, text, text.length(), 1 << 20)
  for split in [(1000, 33), (199999, 4096), (200000, 1), (3, 1 << 20)] {
    let (piece, room) = split
    let (got, _) = written_until_error(200000, text, piece, room)
    assert_true(got == expected, msg="text piece \{piece} room \{room}")
  }
}
