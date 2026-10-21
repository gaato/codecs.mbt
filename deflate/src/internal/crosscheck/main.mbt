// One line per stream, tab-separated: a name, the length and SHA-256 of the
// input, the base64 of the stream, and the base64 of the preset dictionary
// it needs (empty if none). The name begins with the format (raw, zlib or
// gzip); a stream cut after a flush has " flush " in its name and must decode
// to exactly the input before the flush.

///|
/// Inputs: empty, one byte, words, random bytes, zeros, long repeats, and a
/// mix of words and random bytes, past several of the encoder's 64 KiB
/// blocks.
fn samples() -> Array[(String, Bytes)] {
  // The high bits of an LCG: its low ones repeat soon.
  let rng = @fixtures.Rng::new(1950)
  let random = Bytes::makei(150000, _ => (rng.below(1 << 16) >> 8).to_byte())
  [
    ("empty", b""),
    ("byte", b"x"),
    ("text", text(300000)),
    ("random", random),
    ("zeros", Bytes::make(1 << 20, b'\x00')),
    ("mixed", @fixtures.sample(1951, 400000)),
  ]
}

///|
/// `n` bytes of words, deterministic.
fn text(n : Int32) -> Bytes {
  let words : ReadOnlyArray[String] = [
    "the ", "of ", "deflate ", "stream ", "window ", "and ", "block ", "a ", "to ",
    "copy ", "literal ", "distance ", "Huffman ", "code ", "\n", "in ", "is ", "MoonBit ",
    "{\"key\": [1, 2, 3]} ", "<div class=\"x\">", "</div>",
  ]
  let rng = @fixtures.Rng::new(1952)
  let out = Buffer()
  while out.length() < n {
    out.write_string_utf8(words[rng.below(words.length())])
  }
  out.to_bytes()[:n].to_owned()
}

///|
fn emit(
  name : String,
  input : BytesView,
  stream : BytesView,
  dictionary~ : BytesView = b"",
) -> Unit {
  let digest = @fixtures.sha256(input)
  println(
    "\{name}\t\{input.length()}\t\{digest}\t\{@base64.encode(stream)}\t\{@base64.encode(dictionary)}",
  )
}

///|
/// Compresses `input` in `chunk`-byte steps into 1000-byte slices, flushing
/// after every `flush_every` bytes, and emits the stream at every flush and
/// at the end.
fn[E : @codec_bytes.Encode] streamed(
  name : String,
  encoder : E,
  input : Bytes,
  chunk : Int32,
  flush_every : Int32,
  dictionary~ : BytesView = b"",
) -> Unit {
  let out = Buffer()
  let buffer = FixedArray::make(1000, b'\x00')
  let mut pos = 0
  let mut flushes = 0
  for ;; {
    let end = (pos + chunk).min(input.length())
    let at_flush = end / flush_every > pos / flush_every
    let action : @codec_bytes.EncodeAction = if end == input.length() {
      Finish
    } else if at_flush {
      Flush
    } else {
      Continue
    }
    let mut rest = input[pos:end]
    for ;; {
      let status = encoder.step(rest, buffer.mut_view(), action~) catch {
        _ => abort("the encoders never raise")
      }
      rest = rest[encoder.last_consumed():]
      out.write_bytesview(Bytes::from_array(buffer[:encoder.last_produced()]))
      if status is (Done | NeedMoreInput) {
        break
      }
    }
    pos = end
    let label = "\{name} c\{chunk} f\{flush_every}"
    if action is Finish {
      emit(label, input, out.to_bytes(), dictionary~)
      return
    }
    if action is Flush {
      flushes += 1
      emit(
        "\{label} flush \{flushes}",
        input[:pos],
        out.to_bytes(),
        dictionary~,
      )
    }
  }
}

///|
fn main {
  let dictionary = text(50000)[10000:].to_owned()
  let header : @gzip.Header = {
    text: true,
    mtime: 1700000000,
    xfl: b'\x00',
    os: b'\x03',
    extra: Some(b"AB\x04\x00test"),
    name: Some(b"input.txt"),
    comment: Some(b"a comment"),
  }
  for sample in samples() {
    let (name, input) = sample
    for level in 0..<=9 {
      emit("raw \{name} l\{level}", input, @deflate.compress(input, level~))
      emit("zlib \{name} l\{level}", input, @zlib.compress(input, level~))
      emit("gzip \{name} l\{level}", input, @gzip.compress(input, level~))
    }
    for level in [1, 6, 9] {
      emit(
        "raw \{name} l\{level} dict",
        input,
        @deflate.compress(input, level~, dictionary~),
        dictionary~,
      )
      emit(
        "zlib \{name} l\{level} dict",
        input,
        @zlib.compress(input, level~, dictionary~),
        dictionary~,
      )
    }
    emit("gzip \{name} l6 header", input, @gzip.compress(input, header~))
  }
  // Streams flushed as they go, cut after every flush.
  let flushed = text(100000) + @fixtures.sample(7, 60000) + text(40000)
  for level in 0..<=9 {
    streamed(
      "raw flushed l\{level}",
      @deflate.Encoder(level~),
      flushed,
      777,
      10000,
    )
    streamed(
      "zlib flushed l\{level}",
      @zlib.Encoder(level~),
      flushed,
      65536,
      70000,
    )
    streamed(
      "gzip flushed l\{level}",
      @gzip.Encoder(level~),
      flushed,
      4096,
      65537,
    )
  }
  streamed(
    "zlib flushed l6 dict",
    @zlib.Encoder(dictionary~),
    flushed,
    5000,
    20000,
    dictionary~,
  )
  // A flush after every byte.
  streamed(
    "raw bytewise l6",
    @deflate.Encoder(),
    flushed[:300].to_owned(),
    1,
    1,
  )
  streamed(
    "zlib bytewise l1",
    @zlib.Encoder(level=1),
    flushed[:300].to_owned(),
    1,
    1,
  )
}
