// A white-box test of moonbit-community/flate's `Deflater`, run inside a copy
// of flate's root package by deflate/scripts/flate_bounds.mbtx: it reads the
// deflater's private arrays after every step and checks the sizes that
// gaato/deflate's `Encoder::memory_usage` adds up (src/encoder.mbt and
// RESOURCE_BOUNDS.md). Not part of any package of gaato/deflate.

///|
/// The largest size seen of each array, in elements.
priv struct Peak {
  mut ring : Int
  mut short_head : Int
  mut head : Int
  mut prev : Int
  mut tokens : Int
  mut tokens_capacity : Int
  mut out : Int
  mut out_capacity : Int
  mut freq : Int
  mut waiting_input : Int
}

///|
fn Peak::observe(self : Peak, d : Deflater) -> Unit {
  self.ring = self.ring.max(d.pending.length())
  self.short_head = self.short_head.max(d.finder.short_head.length())
  self.head = self.head.max(d.finder.head.length())
  self.prev = self.prev.max(d.finder.prev.length())
  self.tokens = self.tokens.max(d.tokens.length())
  self.tokens_capacity = self.tokens_capacity.max(d.tokens.capacity())
  self.out = self.out.max(d.w.out.length())
  self.out_capacity = self.out_capacity.max(d.w.out.capacity())
  self.freq = self.freq.max(d.ll_freq.length() + d.d_freq.length())
  self.waiting_input = self.waiting_input.max(d.pending_bytes())
}

///|
/// A seeded generator (a 32-bit LCG).
priv struct Lcg {
  mut state : UInt
}

///|
fn Lcg::below(self : Lcg, n : Int) -> Int {
  self.state = self.state * 1664525 + 1013904223
  (self.state >> 8).reinterpret_as_int() % n
}

///|
/// Compresses `input` in `chunk`-byte steps into `room`-byte slices, with a
/// sync flush after every `flush_every` bytes (0: never), observing the
/// deflater after every step, and returns the stream.
fn run(
  peak : Peak,
  input : Bytes,
  level : Int,
  dictionary : Bytes?,
  chunk : Int,
  room : Int,
  flush_every : Int,
) -> Bytes {
  let d = match dictionary {
    Some(dict) => Deflater(level~, dictionary=dict)
    None => Deflater(level~)
  }
  peak.observe(d)
  let out = Buffer()
  let buf = FixedArray::make(room, b'\x00')
  let mut pos = 0
  for ;; {
    let end = (pos + chunk).min(input.length())
    let at_flush = flush_every > 0 && end / flush_every > pos / flush_every
    let action : DeflateAction = if end == input.length() {
      Finish
    } else if at_flush {
      SyncFlush
    } else {
      Continue
    }
    let mut rest = input[pos:end]
    for ;; {
      let status = d.step(rest, buf.mut_view(), action~)
      peak.observe(d)
      rest = rest[d.last_consumed():]
      out.write_bytesview(Bytes::from_array(buf[:d.last_produced()]))
      if status is (Done | NeedMoreInput) {
        break
      }
    }
    pos = end
    if action is Finish {
      return out.to_bytes()
    }
  }
}

///|
test "the deflater's arrays stay within the bounds gaato/deflate counts" {
  let rng = Lcg::{ state: 1951 }
  let random = (n : Int) => {
    Bytes::makei(n, _ => (rng.below(1 << 16) >> 8).to_byte())
  }
  let text = (n : Int) => {
    let words : ReadOnlyArray[String] = [
      "the ", "deflate ", "stream ", "window ", "of ", "a ", "\n", "MoonBit ",
    ]
    let b = Buffer()
    while b.length() < n {
      b.write_string_utf8(words[rng.below(words.length())])
    }
    b.to_bytes()[:n].to_owned()
  }
  let repeats = (n : Int) => {
    let block = random(3000)
    let b = Buffer()
    while b.length() < n {
      let start = rng.below(2000)
      b.write_bytesview(block[start:start + 1 + rng.below(999)])
    }
    b.to_bytes()[:n].to_owned()
  }
  let inputs = [
    text(300000),
    random(200000),
    Bytes::make(300000, b'\x00'),
    repeats(300000),
    text(70000) + random(70000) + text(70000),
  ]
  let peak : Peak = {
    ring: 0,
    short_head: 0,
    head: 0,
    prev: 0,
    tokens: 0,
    tokens_capacity: 0,
    out: 0,
    out_capacity: 0,
    freq: 0,
    waiting_input: 0,
  }
  let dictionary = text(40000)
  // (chunk, room, flush_every): whole, tiny output, small primes, a block's
  // worth with its look-ahead, flushes around a block's size.
  let shapes = [
    (1 << 20, 1 << 16, 0),
    (1 << 20, 1, 0),
    (7, 3, 0),
    (1000, 1000, 0),
    (16642, 0x7fff, 0),
    (999, 1 << 16, 16000),
    (3000, 1 << 16, 16642),
    (1 << 20, 1 << 16, 16643),
    (16641, 1 << 16, 16641),
    (5, 1 << 16, 777),
  ]
  for level in 0..=9 {
    for input in inputs {
      for dict in [None, Some(dictionary)] {
        for shape in shapes {
          let (chunk, room, flush_every) = shape
          let stream = run(peak, input, level, dict, chunk, room, flush_every)
          let inflater = match dict {
            Some(d) => Inflater(dictionary=d)
            None => Inflater()
          }
          let decoded = FixedArray::make(input.length() + 1, b'\x00')
          assert_true(inflater.step_into(stream, decoded, end=true) is Done)
          assert_eq(Bytes::from_array(decoded[:inflater.last_produced()]), input)
        }
      }
    }
  }
  println(
    "ring \{peak.ring}, short_head \{peak.short_head}, head \{peak.head}, prev \{peak.prev}, " +
    "tokens \{peak.tokens} (capacity \{peak.tokens_capacity}), " +
    "output \{peak.out} (capacity \{peak.out_capacity}), freq \{peak.freq}, " +
    "waiting input \{peak.waiting_input}",
  )
  // Fixed when the deflater is made: the mirrored 64 KiB ring, the match
  // finder's tables, the symbol counts.
  assert_eq(peak.ring, 131072)
  assert_eq(peak.short_head, 32768)
  assert_eq(peak.head, 65536)
  assert_eq(peak.prev, 65538)
  assert_eq(peak.freq, 316)
  // Growing with a block: at most a 16 KiB block and its 258 bytes of
  // look-ahead wait; a token for each literal or match beginning inside a
  // block; the output of at most two blocks and a flush, each no larger
  // than stored.
  assert_true(peak.waiting_input <= 16384 + 258)
  assert_true(peak.tokens <= 16384)
  assert_true(peak.tokens_capacity <= 16384)
  assert_true(peak.out <= 16384 + 258 + 2 * 6 + 6)
  assert_true(peak.out_capacity <= 32768)
  // What gaato/deflate's `Encoder::memory_usage` reports, in bytes (4 per
  // Int, 1 per Byte, as on native and Wasm).
  let bound = 131072 + 32768 * 4 + 65536 * 4 + 65538 + 16384 * 4 + 32768 + 316 * 4
  assert_eq(bound, 689394)
  // The bound is reached: every part above at its largest.
  assert_eq(
    peak.ring +
    peak.short_head * 4 +
    peak.head * 4 +
    peak.prev +
    peak.tokens_capacity * 4 +
    peak.out_capacity +
    peak.freq * 4,
    bound,
  )
}
