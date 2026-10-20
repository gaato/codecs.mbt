// One line per check, tab-separated: a name, the length and SHA-256 of the
// input so far, and the base64 of the stream so far. A stream cut after a
// flush must decode to exactly the input before the flush.

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
    "the", "of", "brotli", "stream", "window", "and", "meta-block", "a", "to", "copy",
    "literal", "distance", "prefix", "code", "\n", "in", "is", "MoonBit", "{\"key\": [1, 2, 3]}",
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
/// Bytes from a small alphabet with long-range repeats.
fn repeats(rng : Rng, n : Int32) -> Bytes {
  let out = Buffer()
  let block = random(rng, 3000)
  while out.length() < n {
    let start = rng.below(2000)
    out.write_bytesview(block[start:start + 1 + rng.below(999)])
    out.write_byte(rng.below(4).to_byte())
  }
  out.to_bytes()[:n].to_owned()
}

///|
fn emit(name : String, input : BytesView, stream : BytesView) -> Unit {
  let digest = @checksum.sha256(input)
  println("\{name}\t\{input.length()}\t\{digest}\t\{@base64.encode(stream)}")
}

///|
/// Compresses `input` in `chunk`-byte steps, flushing after every
/// `flush_every` bytes (0: never), and emits the stream at every flush and
/// at the end.
fn streamed(
  name : String,
  input : Bytes,
  window_bits : Int32,
  chunk : Int32,
  flush_every : Int32,
) -> Unit {
  let encoder = @brotli.Encoder(window_bits~)
  let out = Buffer()
  let buffer = FixedArray::make(1000, b'\x00')
  let mut pos = 0
  let mut flushes = 0
  for ;; {
    let end = (pos + chunk).min(input.length())
    let at_flush = flush_every > 0 && end / flush_every > pos / flush_every
    let action : @brotli.EncodeAction = if end == input.length() {
      Finish
    } else if at_flush {
      Flush
    } else {
      Continue
    }
    let mut rest = input[pos:end]
    for ;; {
      let status = encoder.step_into(rest, buffer, action~)
      rest = rest[encoder.last_consumed():]
      out.write_bytesview(
        Bytes::from_array(buffer[:encoder.last_produced()])[:],
      )
      if status is (Done | NeedMoreInput) {
        break
      }
    }
    pos = end
    if action is Finish {
      emit(
        "\{name} w\{window_bits} c\{chunk} f\{flush_every}",
        input,
        out.to_bytes(),
      )
      return
    }
    if action is Flush {
      flushes += 1
      emit(
        "\{name} w\{window_bits} c\{chunk} f\{flush_every} flush \{flushes}",
        input[:pos],
        out.to_bytes(),
      )
    }
  }
}

///|
fn main {
  let rng = Rng::{ state: 7932, }
  let samples = [
    ("empty", b""),
    ("byte", b"x"),
    ("text", text(rng, 300000)),
    ("random", random(rng, 150000)),
    ("zeros", Bytes::make(3 << 20, b'\x00')),
    ("repeats", repeats(rng, 400000)),
    ("mixed", text(rng, 100000) + random(rng, 80000) + text(rng, 100000)),
  ]
  for sample in samples {
    let (name, input) = sample
    for window_bits in [10, 16, 18, 22, 24] {
      emit(
        "\{name} w\{window_bits}",
        input,
        @brotli.compress(input, window_bits~),
      )
    }
  }
  // Far references, beyond one meta-block and across slides of the buffer.
  let far = random(rng, 200000)
  let far_input = far + text(rng, 1 << 20) + far + text(rng, 1 << 21) + far
  for window_bits in [18, 20, 22, 24] {
    emit(
      "far w\{window_bits}",
      far_input,
      @brotli.compress(far_input, window_bits~),
    )
  }
  let flushed = text(rng, 200000) + random(rng, 30000) + text(rng, 50000)
  streamed("flushed", flushed, 22, 777, 10000)
  streamed("flushed", flushed, 16, 65536, 70000)
  // A flush after every byte.
  streamed("bytewise", flushed[:3000].to_owned(), 10, 1, 1)
}
