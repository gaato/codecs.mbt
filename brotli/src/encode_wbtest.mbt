///|
/// Text-like bytes: words from a small vocabulary, seeded.
fn sample_text(rng : Rng, n : Int32) -> Bytes {
  let words = [
    "the", "of", "brotli", "stream", "window", "and", "meta-block", "a", "to", "copy",
    "literal", "distance", "prefix", "code", "\n", "in", "is", "MoonBit",
  ]
  let out = Buffer()
  while out.length() < n {
    out.write_string_utf8(words[rng.below(words.length())])
    out.write_byte(if rng.below(9) == 0 { b'.' } else { b' ' })
  }
  out.to_bytes()[:n].to_owned()
}

///|
fn sample_random(rng : Rng, n : Int32) -> Bytes {
  // The high bits: the low ones of an LCG repeat soon.
  Bytes::makei(n, _ => (rng.below(1 << 16) >> 8).to_byte())
}

///|
/// Random blocks that come back 1 KiB to 1 MiB later, past every window.
fn far_repeats(rng : Rng) -> Bytes {
  let block = sample_random(rng, 3000)
  let out = Buffer()
  for gap in [500, 1100, 70000, 300000, 1100000] {
    out.write_bytes(block)
    out.write_bytes(sample_text(rng, gap))
  }
  out.write_bytes(block)
  out.to_bytes()
}

///|
/// Inputs for the encoder: edge cases, synthetic data and the originals of
/// the decoder's vectors.
fn sample_inputs() -> Array[(String, Bytes)] raise {
  let rng = Rng::new(2026)
  let inputs = [
    ("empty", b""),
    ("one byte", b"a"),
    ("hello", b"hello"),
    ("text", sample_text(rng, 200000)),
    ("random", sample_random(rng, 100000)),
    ("zeros", Bytes::make(1 << 20, b'\x00')),
    ("far", far_repeats(rng)),
    (
      "mixed",
      sample_text(rng, 70000) +
      sample_random(rng, 70000) +
      sample_text(rng, 70000),
    ),
  ]
  for v in vectors {
    inputs.push((v.name, decompress(v.input())))
  }
  inputs
}

///|
test "compress round-trips through the decoder" {
  for sample in sample_inputs() {
    let (name, input) = sample
    for wbits in [10, 16, 22, 24] {
      let compressed = compress(input, window_bits=wbits)
      let got = decompress(compressed)
      assert_eq(got.length(), input.length(), msg="\{name} wbits \{wbits}")
      assert_true(got == input, msg="\{name} wbits \{wbits}")
    }
  }
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
test "any fixed input split and output size give the same stream" {
  let splits : Array[(Int32, Int32)] = [
    (1, 1 << 16),
    (1 << 16, 1),
    (1, 1),
    (7, 3),
    (4096, 64),
    (100000, 100000),
  ]
  for sample in sample_inputs() {
    let (name, input) = sample
    guard input.length() <= 300000 else { continue }
    let whole = encode_drive(
      Encoder(window_bits=18),
      input,
      next_in=() => 1 << 22,
      next_out=() => 1 << 22,
    )
    assert_true(decompress(whole) == input, msg=name)
    for split in splits {
      let (in_chunk, out_chunk) = split
      if in_chunk * out_chunk < 64 && input.length() > 20000 {
        continue
      }
      let got = encode_drive(
        Encoder(window_bits=18),
        input,
        next_in=() => in_chunk,
        next_out=() => out_chunk,
        fixed=in_chunk != 7,
      )
      assert_true(got == whole, msg="\{name} in \{in_chunk} out \{out_chunk}")
    }
  }
}

///|
test "a flush makes the stream so far decode to the input so far" {
  let rng = Rng::new(1951)
  let mut flushes = 0
  for sample in sample_inputs() {
    let (name, input) = sample
    guard input.length() <= 300000 else { continue }
    for round in 0..<3 {
      let max_in = [1, 300, 70000][round]
      let max_out = [7, 5000, 1 << 17][round]
      let every = [97, 1000, 1][round]
      // The stream so far goes to one decoder as it grows.
      let decoder = Decoder()
      let decoded = Buffer()
      let mut fed = 0
      let stream = encode_drive(
        Encoder(window_bits=[10, 16, 22][round]),
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
  assert_true(flushes > 1000)
}

///|
test "incompressible input costs a few bytes per meta-block" {
  let rng = Rng::new(16)
  for n in [1, 1000, 65536, 65537, 300000] {
    let input = sample_random(rng, n)
    let compressed = compress(input)
    assert_true(compressed.length() <= n + 5 * (n / BLOCK_SIZE + 1) + 2)
    assert_true(decompress(compressed) == input)
  }
}

///|
test "the encoder's codes invert the decoder's tables" {
  for len in 0..<30000 {
    let ic = insert_code(len)
    let base = insert_length_base[ic]
    assert_true(base <= len && len - base < 1 << insert_length_extra[ic])
  }
  for len in [16777216, 22594, 22593, 6210] {
    let ic = insert_code(len)
    let base = insert_length_base[ic]
    assert_true(base <= len && len - base < 1 << insert_length_extra[ic])
  }
  for len in 2..<30000 {
    let cc = copy_code(len)
    let base = copy_length_base[cc]
    assert_true(base <= len && len - base < 1 << copy_length_extra[cc])
  }
  for ic in 0..<24 {
    for cc in 0..<24 {
      for last in [false, true] {
        let sym = command_symbol(ic, cc, last)
        let cell = sym >> 6
        assert_eq(cell_insert_base[cell] + ((sym >> 3) & 7), ic)
        assert_eq(cell_copy_base[cell] + (sym & 7), cc)
        // Only these cells reuse the last distance implicitly.
        assert_eq(sym < 128, last && ic < 8 && cc < 16)
      }
    }
  }
  // The decoder's distance formula, NPOSTFIX and NDIRECT 0.
  let decode = (sym : Int32, extra : Int32) => {
    let c = sym - 16
    let bits = 1 + (c >> 1)
    ((2 + (c & 1)) << bits) - 4 + extra + 1
  }
  let dists = [(1 << 24) - 16, (1 << 24) - 17, 1 << 20]
  for d in 1..<5000 {
    dists.push(d)
  }
  for d in dists {
    let sym = distance_symbol(d)
    let extra = distance_extra(d)
    assert_true(sym >= 16 && sym < DISTANCE_ALPHABET)
    assert_true(extra >= 0 && extra < 1 << distance_extra_bits(sym))
    assert_eq(decode(sym, extra), d)
  }
  for v in 0..<6 {
    let ix = code_length_code[v]
    assert_eq(code_length_prefix_value[ix], v)
    assert_eq(code_length_prefix_bits[ix], code_length_code_bits[v])
  }
}

///|
test "prefix codes of every shape decode" {
  let inputs : Array[Bytes] = [
    // One literal, one insert-and-copy symbol, no distance.
    Bytes::make(5000, b'a'),
    // Two, three and four literals, with lengths 2, 2, 2, 2 and 1, 2, 3, 3.
    b"ab".repeat(1000),
    b"abacabacabac" + b"x",
    b"abcd",
    b"aaaaaaaabbbcd",
    // Every byte value once, then a long match: 256 literals of length 8,
    // whose code lengths are a single repeat code.
    Bytes::makei(256, i => i.to_byte()).repeat(20),
  ]
  for input in inputs {
    assert_true(decompress(compress(input)) == input)
  }
}

///|
test "steps after the end take no input" {
  let encoder = Encoder()
  let out = FixedArray::make(64, b'\x00')
  debug_inspect(encoder.step_into(b"hello", out), content="NeedMoreInput")
  inspect(encoder.last_consumed(), content="5")
  inspect(encoder.last_produced(), content="0")
  inspect(encoder.is_finished(), content="false")
  debug_inspect(encoder.step_into(b"", out, action=Finish), content="Done")
  let stream = Bytes::from_array(out[:encoder.last_produced()])
  assert_true(decompress(stream) == b"hello")
  debug_inspect(encoder.step_into(b"more", out, action=Finish), content="Done")
  inspect(encoder.last_consumed(), content="0")
  inspect(encoder.last_produced(), content="0")
  // A reset encoder makes the same stream again.
  encoder.reset()
  inspect(encoder.is_finished(), content="false")
  debug_inspect(encoder.step_into(b"hello", out, action=Finish), content="Done")
  assert_true(Bytes::from_array(out[:encoder.last_produced()]) == stream)
}

///|
test "flushes with nothing new add nothing" {
  let encoder = Encoder()
  let out = FixedArray::make(64, b'\x00')
  // A flush before any input: the stream header, padded.
  debug_inspect(
    encoder.step_into(b"", out, action=Flush),
    content="NeedMoreInput",
  )
  inspect(encoder.last_produced(), content="2")
  debug_inspect(
    encoder.step_into(b"", out, action=Flush),
    content="NeedMoreInput",
  )
  inspect(encoder.last_produced(), content="0")
  debug_inspect(
    encoder.step_into(b"abc", out, action=Flush),
    content="NeedMoreInput",
  )
  let first = encoder.last_produced()
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
  inspect(first > 0 && encoder.last_produced() > 0, content="true")
  // Finish overrides a flush.
  debug_inspect(encoder.step_into(b"", out, action=Finish), content="Done")
}

///|
test "window_bits is clamped and compress shrinks the window to the input" {
  inspect(Encoder(window_bits=8).window_bits, content="10")
  inspect(Encoder(window_bits=30).window_bits, content="24")
  // The first bits of a stream are its WBITS (section 9.1).
  let wbits = (stream : Bytes) => {
    let b = stream[0].to_int() | (stream[1].to_int() << 8)
    if (b & 1) == 0 {
      16
    } else if ((b >> 1) & 7) != 0 {
      17 + ((b >> 1) & 7)
    } else if ((b >> 4) & 7) != 0 {
      8 + ((b >> 4) & 7)
    } else {
      17
    }
  }
  inspect(wbits(compress(b"small")), content="16")
  inspect(wbits(compress(b"small", window_bits=12)), content="12")
  let big = Bytes::make(100000, b'z')
  inspect(wbits(compress(big)), content="17")
  inspect(wbits(compress(big, window_bits=24)), content="17")
  inspect(
    wbits(compress(Bytes::make(70000, b'z'), window_bits=17)),
    content="17",
  )
  inspect(wbits(compress(Bytes::make(200000, b'z'))), content="18")
  for w in [10, 11, 15, 16, 17, 18, 24] {
    let stream = encode_drive(Encoder(window_bits=w), b"abc", next_in=() => 3, next_out=() => {
      100
    })
    assert_eq(wbits(stream + b"\x00"), w)
    assert_true(decompress(stream, max_window_bits=w) == b"abc")
  }
}
