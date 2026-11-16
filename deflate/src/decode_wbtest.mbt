///|
test "every vector decodes to its original" {
  for v in vectors {
    let got = decompress(v.input())
    assert_eq(got.length(), v.size, msg=v.name)
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "streams with a preset dictionary decode with it, and only with it" {
  for entry in dictionary_vectors {
    let (v, dictionary) = entry
    let dictionary = @fixtures.decode64(dictionary)
    let decoder = Decoder(dictionary~)
    let (got, _) = @fixtures.drive(decoder, v.input(), next_in=() => 1000, next_out=() => {
      4096
    })
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
    // `reset` keeps the dictionary.
    decoder.reset()
    let (again, _) = @fixtures.drive(
      decoder,
      v.input(),
      next_in=() => 1 << 20,
      next_out=() => 1 << 16,
      step_into=into,
    )
    assert_eq(again, got, msg=v.name)
    assert_eq(refusal(v.input()), Corrupt, msg=v.name)
    assert_eq(
      @fixtures.sha256(decompress(v.input(), dictionary~)),
      v.sha256,
      msg=v.name,
    )
  }
}

///|
test "any fixed input split and output size give the same output" {
  let splits : Array[(Int32, Int32)] = [
    (1, 1 << 16),
    (1 << 20, 1),
    (1, 1),
    (3, 7),
    (7, 3),
    (64, 4096),
    (4096, 64),
  ]
  for v in vectors {
    guard v.size <= 300000 else { continue }
    let input = v.input()
    for split in splits {
      let (in_chunk, out_chunk) = split
      if in_chunk * out_chunk < 64 && v.size > 20000 {
        continue
      }
      for fixed in [false, true] {
        let (got, consumed) = @fixtures.drive(
          Decoder(),
          input,
          next_in=() => in_chunk,
          next_out=() => out_chunk,
          step_into?=if fixed { Some(into) } else { None },
        )
        let label = "\{v.name} in \{in_chunk} out \{out_chunk}"
        assert_eq(@fixtures.sha256(got), v.sha256, msg=label)
        assert_eq(consumed, input.length(), msg=label)
      }
    }
  }
}

///|
test "random input splits and output sizes give the same output" {
  let rng = @fixtures.Rng::new(1951)
  for v in vectors {
    let input = v.input()
    for round in 0..<3 {
      let max_in = [1, 17, 1500][round]
      let max_out = [5000, 3, 70000][round]
      if v.size > 300000 && round != 2 {
        continue
      }
      let (got, _) = @fixtures.drive(
        Decoder(),
        input,
        next_in=() => 1 + rng.below(max_in),
        next_out=() => 1 + rng.below(max_out),
        step_into?=if round != 1 { Some(into) } else { None },
      )
      assert_eq(@fixtures.sha256(got), v.sha256, msg="\{v.name} round \{round}")
    }
  }
}

///|
test "every proper prefix is truncated" {
  for v in vectors {
    let input = v.input()
    guard input.length() <= 3000 else { continue }
    for cut in 0..<input.length() {
      assert_eq(refusal(input[:cut]), Truncated, msg="\{v.name} cut at \{cut}")
    }
  }
}

///|
test "until=EndOfMember leaves what follows the final block, under every split" {
  let rest = b"what follows"
  for name in ["small_level6", "small_level0", "mixed_sync_flushed", "empty"] {
    let v = vector(name)
    let input = Bytes::from_array([..v.input(), ..rest])
    for split in [(1, 1), (3, 7), (1 << 20, 1 << 16), (64, 1)] {
      let (in_chunk, out_chunk) = split
      let decoder = Decoder(until=EndOfMember)
      let (got, consumed) = @fixtures.drive(
        decoder,
        input,
        next_in=() => in_chunk,
        next_out=() => out_chunk,
      )
      assert_eq(@fixtures.sha256(got), v.sha256, msg=name)
      assert_eq(input[consumed:], rest, msg=name)
      assert_true(decoder.is_finished())
      // Done again, consuming nothing.
      let out = FixedArray::make(8, b'\x00')
      assert_true(decoder.step_into(rest, out, end=true) is Done)
      assert_eq(decoder.last_consumed(), 0)
    }
  }
}

///|
test "is_finished stays false while output from the final block waits" {
  let stream = vector("small_level9").input()
  let out = FixedArray::make(1, b'\x00')
  let decoder = Decoder()
  let mut rest = stream[:]
  let mut produced = 0
  for ;; {
    let status = decoder.step_into(rest, out, end=false)
    rest = rest[decoder.last_consumed():]
    produced += decoder.last_produced()
    if status is NeedMoreOutput {
      assert_false(decoder.is_finished())
    } else {
      break
    }
  }
  assert_true(produced > 1)
  assert_true(decoder.is_finished())
}

///|
test "until=EndOfInput: Done waits for end, and bytes after the stream are trailing" {
  let stream = vector("small_level9").input()
  let out = FixedArray::make(1 << 16, b'\x00')
  let decoder = Decoder()
  assert_true(decoder.step_into(stream, out, end=false) is NeedMoreInput)
  assert_eq(decoder.last_consumed(), stream.length())
  assert_true(decoder.is_finished())
  // More input, even empty, without end: still waiting.
  assert_true(decoder.step_into(b"", out, end=false) is NeedMoreInput)
  assert_true(decoder.step_into(b"", out, end=true) is Done)
  // After Done, any byte is trailing.
  assert_true(decoder.step_into(b"", out, end=true) is Done)
  let after = try decoder.step_into(b"x", out, end=true) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(after, TrailingData)
  // A byte after the final block, in a later step.
  let later = Decoder()
  let _ = later.step_into(stream, out, end=false)
  let kind = try later.step_into(b"\x00", out, end=true) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(kind, TrailingData)
  assert_eq(refusal(Bytes::from_array([..stream, 0])), TrailingData)
}

///|
test "errors stick until reset, and reset forgets the stream" {
  let stream = vector("small_level1").input()
  let decoder = Decoder()
  let out = FixedArray::make(64, b'\x00')
  let bad = b"\x07\x00"
  let first = try decoder.step_into(bad, out, end=true) catch {
    CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => "decoded"
  }
  inspect(first, content="Corrupt: a block of the reserved type (BTYPE 3)")
  // The step took the byte that holds BTYPE.
  assert_eq(decoder.last_consumed(), 1)
  assert_eq(decoder.last_produced(), 0)
  let again = try decoder.step_into(stream, out, end=true) catch {
    CodecError(kind, _) => Some(kind)
  } noraise {
    _ => None
  }
  assert_eq(again, Some(Corrupt))
  decoder.reset()
  let (got, _) = @fixtures.drive(decoder, stream, next_in=() => 100, next_out=() => {
    100
  })
  assert_eq(@fixtures.sha256(got), vector("small_level1").sha256)
  // Reset in the middle of a stream.
  decoder.reset()
  let _ = decoder.step_into(stream[:200], out, end=false)
  decoder.reset()
  let (got, _) = @fixtures.drive(decoder, stream, next_in=() => 7, next_out=() => {
    1000
  })
  assert_eq(@fixtures.sha256(got), vector("small_level1").sha256)
}

///|
test "messages say what is wrong" {
  let message = (input : Bytes) => {
    try decompress(input) catch {
      CodecError(kind, message) => "\{Repr(kind)}: \{message}"
    } noraise {
      _ => "decoded"
    }
  }
  inspect(
    message(b""),
    content="Truncated: the input ends inside the DEFLATE data",
  )
  inspect(
    message(b"\x01\x05\x00\xfb\xff"),
    content="Corrupt: a stored block's LEN and NLEN disagree",
  )
}

///|
test "decompress honours max_output" {
  let v = vector("text_level6")
  let input = v.input()
  assert_eq(decompress(input, max_output=v.size).length(), v.size)
  let over = try decompress(input, max_output=v.size - 1) catch {
    CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => "decoded"
  }
  inspect(
    over,
    content="LimitExceeded({ resource: Output, needed: None, limit: 19999 }): the output exceeds 19999 bytes",
  )
}

///|
test "the decoder is a gaato/codec_bytes Decode" {
  let v = vector("small_level6")
  let decoder = Decoder()
  for _ in 0..<2 {
    let (got, _) = @fixtures.drive(decoder, v.input(), next_in=() => 7, next_out=() => {
      10
    })
    assert_eq(@fixtures.sha256(got), v.sha256)
    assert_eq(
      @codec_bytes.Decode::memory_usage(decoder),
      decoder.memory_usage(),
    )
    @codec_bytes.Decode::reset(decoder)
  }
}

///|
test "a step that raises reports what it took and wrote" {
  let v = vector("text_level6")
  let stream = v.input()
  let out = FixedArray::make(v.size, b'\x00')
  // A byte after the final block: the stream to its end, all its output.
  let decoder = Decoder()
  let kind = try
    decoder.step_into(Bytes::from_array([..stream, 0]), out, end=true)
  catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(kind, TrailingData)
  assert_eq(decoder.last_consumed(), stream.length())
  assert_eq(decoder.last_produced(), v.size)
  assert_eq(@fixtures.sha256(Bytes::from_array(out[:v.size])), v.sha256)
  // Cut short: everything given, and the output so far.
  let decoder = Decoder()
  let cut = stream[:stream.length() - 1]
  let kind = try decoder.step_into(cut, out, end=true) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(kind, Truncated)
  assert_eq(decoder.last_consumed(), cut.length())
  assert_true(decoder.last_produced() > v.size - 300)
  // A stored block, then a reserved block type: "hello", and the byte that
  // holds BTYPE.
  let decoder = Decoder()
  let hello = b"\x00\x05\x00\xfa\xffhello\x07"
  let kind = try decoder.step_into(hello, out, end=true) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
  assert_eq(kind, Corrupt)
  assert_eq(Bytes::from_array(out[:5]), b"hello")
  assert_eq(decoder.last_consumed(), hello.length())
  assert_eq(decoder.last_produced(), 5)
}

///|
/// `chunks` coded at `level` with a sync flush after each, unfinished, and
/// where each flush ends.
fn flushed(chunks : Array[Bytes], level : Int32) -> (Bytes, Array[Int32]) {
  let encoder = Encoder(level~)
  let buffer : Array[Byte] = []
  let ends = []
  let out = FixedArray::make(1 << 16, b'\x00')
  for chunk in chunks {
    let _ = encoder.step_into(chunk, out, action=Flush)
    assert_eq(encoder.last_consumed(), chunk.length()) catch {
      _ => abort("short flush")
    }
    buffer.append(out[:encoder.last_produced()])
    ends.push(buffer.length())
  }
  (Bytes::from_array(buffer), ends)
}

///|
/// Feeds `input` whole (end=false) to `decoder` and returns what it wrote.
fn feed(decoder : Decoder, input : BytesView) -> Bytes raise {
  let out = FixedArray::make(1 << 16, b'\x00')
  let status = decoder.step_into(input, out, end=false)
  assert_true(status is NeedMoreInput)
  assert_eq(decoder.last_consumed(), input.length())
  Bytes::from_array(out[:decoder.last_produced()])
}

///|
test "at_block_boundary is true exactly where a sync flush ends" {
  let chunks = [b"hello hello hello", b"", b"world, world", b"x"]
  for level in [0, 1, 6, 9] {
    let (stream, ends) = flushed(chunks, level)
    for cut in 0..<=stream.length() {
      let decoder = Decoder()
      let _ = feed(decoder, stream[:cut])
      // Every flush ends on one; the start of the stream is one too.
      if cut == 0 || ends.contains(cut) {
        assert_true(
          decoder.at_block_boundary(),
          msg="level \{level} cut \{cut}",
        )
      }
      // RFC 7692 drops each flush's 00 00 ff ff: the cut before it is not.
      if ends.contains(cut + 4) {
        assert_false(
          decoder.at_block_boundary(),
          msg="level \{level} cut \{cut}",
        )
      }
    }
  }
}

///|
test "at_block_boundary does not depend on how the input was split" {
  let (stream, _) = flushed([b"abcabcabc", b"q", b"", b"the end of it"], 6)
  let whole = []
  for cut in 0..<=stream.length() {
    let decoder = Decoder()
    let _ = feed(decoder, stream[:cut])
    whole.push(decoder.at_block_boundary())
  }
  for first in 0..<=stream.length() {
    for second in first..<=stream.length() {
      let decoder = Decoder()
      let _ = feed(decoder, stream[:first])
      let _ = feed(decoder, stream[first:second])
      assert_eq(
        decoder.at_block_boundary(),
        whole[second],
        msg="\{first} \{second}",
      )
    }
  }
  // A block ends inside the last byte, and the bits after it are the start
  // of the next block's header: held, so not a boundary.
  let decoder = Decoder()
  let _ = feed(decoder, b"\x9a\x30\x61\xc2\x04\x00")
  assert_false(decoder.at_block_boundary())
}

///|
test "at_block_boundary is false inside a block, though the input adds nothing" {
  // A fixed-code block (BFINAL 0, BTYPE 01) of five 9-bit literals ends on a
  // byte with its end-of-block code still to come. RFC 7692's 00 00 ff ff
  // then reads as that code (seven zeros), a non-final stored block and its
  // LEN, and the decoder waits for NLEN: no output, and no boundary.
  let bits = BitSink::new()
  bits.put(0, 1)
  bits.put(1, 2)
  for _ in 0..<5 {
    bits.put_code(0b110010000, 9) // the literal 144
  }
  let message = bits.to_bytes()
  assert_eq(message.length(), 6)
  let decoder = Decoder()
  assert_eq(feed(decoder, message), b"\x90\x90\x90\x90\x90")
  assert_false(decoder.at_block_boundary())
  assert_eq(feed(decoder, b"\x00\x00\xff\xff"), b"")
  assert_false(decoder.at_block_boundary())
}

///|
test "at_block_boundary is false with output still held, after the end and after an error" {
  let (stream, ends) = flushed([b"abcdefgh"], 0)
  let decoder = Decoder()
  let out = FixedArray::make(3, b'\x00')
  let _ = decoder.step_into(stream[:ends[0]], out, end=false)
  assert_false(decoder.at_block_boundary())
  let _ = decoder.step_into(
    stream[decoder.last_consumed():ends[0]],
    out,
    end=false,
  )
  assert_false(decoder.at_block_boundary())
  let _ = decoder.step_into(b"", out, end=false)
  assert_true(decoder.at_block_boundary())
  let finished = Decoder()
  let _ = feed(finished, compress(b"abc"))
  assert_false(finished.at_block_boundary())
  let failed = Decoder()
  let _ = failed.step_into(b"\x07", out, end=false) catch { _ => NeedMoreInput }
  assert_false(failed.at_block_boundary())
}

///|
test "reset can change the dictionary, and later resets keep it" {
  for entry in dictionary_vectors {
    let (v, dictionary) = entry
    let dictionary = @fixtures.decode64(dictionary)
    let decoder = Decoder()
    decoder.reset(dictionary~)
    let (got, _) = @fixtures.drive(decoder, v.input(), next_in=() => 1000, next_out=() => {
      4096
    })
    assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
    decoder.reset()
    let (again, _) = @fixtures.drive(
      decoder,
      v.input(),
      next_in=() => 1 << 20,
      next_out=() => 1 << 16,
    )
    assert_eq(again, got, msg=v.name)
    // Its last 32 KiB count, as for the constructor's: the stream never
    // reaches past the dictionary into what comes before it.
    let padded : Array[Byte] = Array::make(40000, b'z')
    for b in dictionary {
      padded.push(b)
    }
    decoder.reset(dictionary=Bytes::from_array(padded))
    let (padded_got, _) = @fixtures.drive(
      decoder,
      v.input(),
      next_in=() => 1 << 20,
      next_out=() => 1 << 16,
    )
    assert_eq(padded_got, got, msg=v.name)
  }
}

///|
/// Bits, least significant first, as DEFLATE packs them.
priv struct BitSink {
  bytes : Array[Byte]
  mut acc : Int32
  mut n : Int32
}

///|
fn BitSink::new() -> BitSink {
  { bytes: [], acc: 0, n: 0, }
}

///|
fn BitSink::put(self : BitSink, value : Int32, n : Int32) -> Unit {
  self.acc = self.acc | (value << self.n)
  self.n += n
  while self.n >= 8 {
    self.bytes.push((self.acc & 0xFF).to_byte())
    self.acc = self.acc >> 8
    self.n -= 8
  }
}

///|
/// A Huffman code, most significant bit first.
fn BitSink::put_code(self : BitSink, code : Int32, n : Int32) -> Unit {
  for i = n - 1; i >= 0; i = i - 1 {
    self.put((code >> i) & 1, 1)
  }
}

///|
fn BitSink::to_bytes(self : BitSink) -> Bytes {
  if self.n > 0 {
    self.bytes.push((self.acc & 0xFF).to_byte())
  }
  Bytes::from_array(self.bytes)
}

///|
test "RFC 7692's final-block message: Done, then a reset with the output so far" {
  // Section 7.2.3.4: "Hello" in a final block, then the receiver's tail.
  let input = b"\xf3\x48\xcd\xc9\xc9\x07\x00\x00\x00\x00\xff\xff"
  let decoder = Decoder(until=EndOfMember)
  let out = FixedArray::make(64, b'\x00')
  let status = decoder.step_into(input, out, end=false)
  assert_true(status is Done)
  let hello = Bytes::from_array(out[:decoder.last_produced()])
  assert_eq(hello, b"Hello")
  assert_false(decoder.at_block_boundary())
  let rest = input[decoder.last_consumed():]
  assert_eq(rest.to_owned(), b"\x00\x00\x00\xff\xff")
  // The next blocks go on with the same window: an empty stored block.
  decoder.reset(dictionary=hello)
  assert_eq(feed(decoder, rest), b"")
  assert_true(decoder.at_block_boundary())
}

///|
test "RFC 7692: a message that leaves a stored block open takes the tail as data" {
  // A non-final stored block of 4 bytes with none of them sent: the
  // receiver's 00 00 ff ff become its data, and the decoder then stands at
  // a boundary. Only the output of the tail tells this from a sync flush.
  let decoder = Decoder(until=EndOfMember)
  assert_eq(feed(decoder, b"\x00\x04\x00\xfb\xff"), b"")
  assert_false(decoder.at_block_boundary())
  assert_eq(feed(decoder, b"\x00\x00\xff\xff"), b"\x00\x00\xff\xff")
  assert_true(decoder.at_block_boundary())
}

///|
test "a reset without a dictionary keeps the last one given; an empty one clears it" {
  let dictionary = b"a dictionary to refer to"
  let stream = compress(b"to refer to", dictionary~)
  let decoder = Decoder()
  decoder.reset(dictionary~)
  decoder.reset()
  let (got, _) = @fixtures.drive(decoder, stream, next_in=() => 1 << 10, next_out=() => {
    1 << 10
  })
  assert_eq(got, b"to refer to")
  decoder.reset(dictionary=b"")
  let refused = try decompress_with(decoder, stream) catch {
    CodecError(kind, _) => Some(kind)
  } noraise {
    _ => None
  }
  assert_true(refused is Some(_))
}

///|
fn decompress_with(
  decoder : Decoder,
  input : BytesView,
) -> Bytes raise @codec.CodecError {
  let out = FixedArray::make(1 << 10, b'\x00')
  let _ = decoder.step_into(input, out, end=true)
  Bytes::from_array(out[:decoder.last_produced()])
}
