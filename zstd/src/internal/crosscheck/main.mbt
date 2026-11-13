// One line per check, tab-separated: a name, the length and SHA-256 of the
// input so far, and the base64 of the stream so far. A stream cut after a
// flush has " flush " in its name and must decode to exactly the input
// before the flush.

///|
/// A seeded pseudo-random generator (a 32-bit LCG).
priv struct Rng {
  mut state : UInt32
}

///|
fn Rng::below(self : Rng, bound : Int32) -> Int32 {
  self.state = self.state * 1664525 + 1013904223
  (self.state >> 8).reinterpret_as_int() % bound
}

///|
fn text(rng : Rng, n : Int32) -> Bytes {
  let words = [
    "the", "of", "zstd", "frame", "window", "and", "block", "a", "to", "sequence",
    "literal", "offset", "Huffman", "FSE", "\n", "in", "is", "MoonBit", "{\"key\": [1, 2, 3]}",
    "<div class=\"x\">", "</div>",
  ]
  let out = Buffer()
  while out.length() < n {
    out.write_string_utf8(words[rng.below(words.length())])
    out.write_byte(if rng.below(9) == 0 { b'.' } else { b' ' })
  }
  out.to_bytes()[:n].to_owned()
}

///|
fn random(rng : Rng, n : Int32) -> Bytes {
  // The high bits: the low ones of an LCG repeat soon.
  Bytes::makei(n, _ => (rng.below(1 << 16) >> 8).to_byte())
}

///|
/// Bytes of a few values in skewed proportions: Huffman codes of every
/// length up to the limit.
fn skewed(rng : Rng, n : Int32) -> Bytes {
  Bytes::makei(n, _ => {
    let r = rng.below(1 << 16)
    (31 - (r | 1).clz() + (r & 1) * 64).to_byte()
  })
}

///|
fn emit(name : String, input : BytesView, stream : BytesView) -> Unit {
  let digest = @checksum.sha256(input)
  println("\{name}\t\{input.length()}\t\{digest}\t\{@base64.encode(stream)}")
}

///|
/// Compresses `input` in `chunk`-byte steps into 1000-byte slices, flushing
/// after every `flush_every` bytes (0: never), and emits the stream at
/// every flush and at the end.
fn streamed(
  name : String,
  encoder : @zstd.Encoder,
  input : Bytes,
  chunk : Int32,
  flush_every : Int32,
) -> Unit {
  let out = Buffer()
  let buffer = FixedArray::make(1000, b'\x00')
  let mut pos = 0
  let mut flushes = 0
  for ;; {
    let end = (pos + chunk).min(input.length())
    let at_flush = flush_every > 0 && end / flush_every > pos / flush_every
    let action : @zstd.EncodeAction = if end == input.length() {
      Finish
    } else if at_flush {
      Flush
    } else {
      Continue
    }
    let mut rest = input[pos:end]
    for ;; {
      // Without a content size the encoder never raises.
      let status = try! encoder.step_into(rest, buffer, action~)
      rest = rest[encoder.last_consumed():]
      out.write_bytesview(
        Bytes::from_array(buffer[:encoder.last_produced()])[:],
      )
      if status is (Done | NeedMoreInput) {
        break
      }
    }
    pos = end
    let label = "\{name} c\{chunk} f\{flush_every}"
    if action is Finish {
      emit(label, input, out.to_bytes())
      return
    }
    if action is Flush {
      flushes += 1
      emit("\{label} flush \{flushes}", input[:pos], out.to_bytes())
    }
  }
}

///|
fn main {
  for c in @seqcases.cases() {
    emit("sequence-\{c.name}", c.input, c.frame)
  }
  let rng = Rng::{ state: 8878, }
  let samples = [
    ("empty", b""),
    ("byte", b"x"),
    ("two", b"xy"),
    ("text", text(rng, 300000)),
    ("random", random(rng, 150000)),
    ("skewed", skewed(rng, 200000)),
    ("zeros", Bytes::make(3 << 20, b'\x00')),
    ("mixed", text(rng, 100000) + random(rng, 80000) + text(rng, 100000)),
  ]
  // The literals headers' size classes, the block limit, and the parameter
  // tables' size classes.
  for
    n in [
      5, 6, 31, 32, 255, 256, 1023, 1024, 4095, 4096, 16383, 16384, 16385, 131071,
      131072, 131073, 262143, 262144, 262145,
    ] {
    samples.push(("text\{n}", text(rng, n)))
  }
  for sample in samples {
    let (name, input) = sample
    for level in 1..<=12 {
      emit("\{name} l\{level}", input, @zstd.compress(input, level~))
    }
    emit("\{name} l3 nocheck", input, @zstd.compress(input, checksum=false))
    // Without the content size: a window descriptor, and no size.
    streamed("\{name} l3 unsized", @zstd.Encoder(), input, 65536, 0)
  }
  let flushed = text(rng, 200000) + random(rng, 30000) + text(rng, 50000)
  streamed("flushed l1", @zstd.Encoder(level=1), flushed, 777, 10000)
  streamed("flushed l4", @zstd.Encoder(level=4), flushed, 777, 10000)
  streamed("flushed l5", @zstd.Encoder(level=5), flushed, 777, 10000)
  streamed("flushed l6", @zstd.Encoder(level=6), flushed, 777, 10000)
  streamed("flushed l8", @zstd.Encoder(level=8), flushed, 777, 10000)
  streamed("flushed l12", @zstd.Encoder(level=12), flushed, 65536, 70000)
  streamed(
    "flushed l3 nocheck",
    @zstd.Encoder(checksum=false),
    flushed,
    4096,
    131072,
  )
  // A flush after every byte.
  streamed("bytewise l3", @zstd.Encoder(), flushed[:1000].to_owned(), 1, 1)
  streamed(
    "bytewise l4",
    @zstd.Encoder(level=4),
    flushed[:20000].to_owned(),
    1,
    0,
  )
  for level in [5, 6, 8, 12] {
    streamed(
      "bytewise l\{level}",
      @zstd.Encoder(level~),
      flushed[:20000].to_owned(),
      1,
      0,
    )
  }
  // Reuse a nontrivial prefix across cutter blocks and around a 2 MiB
  // window. Both long hashes and the history eviction path are exercised.
  let prefix = random(rng, 100000)
  let distant = prefix + random(rng, (1 << 21) - 100001) + prefix + prefix
  for level in [3, 4, 5, 6, 8, 12] {
    emit("distant l\{level}", distant, @zstd.compress(distant, level~))
  }
}
