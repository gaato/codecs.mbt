///|
/// Bytes from a seeded LCG: text from a small vocabulary, or noise.
fn sample(n : Int32, seed : UInt64, text~ : Bool) -> Bytes {
  let words = [
    "the ", "lzw ", "code ", "table ", "of ", "clear ", "string ", "and ", "a ",
    "image ", "\n",
  ]
  let mut state = seed
  let next = (bound : Int32) => {
    state = state * 6364136223846793005UL + 1442695040888963407UL
    ((state >> 33) % bound.to_uint64()).to_int()
  }
  if !text {
    return Bytes::makei(n, _ => next(256).to_byte())
  }
  let out = Buffer()
  while out.length() < n {
    out.write_string_utf8(words[next(words.length())])
  }
  out.to_bytes()[:n].to_owned()
}

///|
/// The sets: a name, the format, and the bits a GIF minimum code size keeps
/// of each input byte (8 for the others).
fn sets() -> Array[(String, @lzw.Format, Int32)] raise @codec.CodecError {
  [
    ("gif-2", @lzw.Format::gif(2), 2),
    ("gif-4", @lzw.Format::gif(4), 4),
    ("gif-8", @lzw.Format::gif(8), 8),
    ("tiff", @lzw.Format::tiff(), 8),
    ("msb", @lzw.Format::pdf(early_change=false), 8),
    ("z16", @lzw.Format::unix_compress(), 8),
    ("z12", @lzw.Format::unix_compress(max_bits=12), 8),
    ("z10", @lzw.Format::unix_compress(max_bits=10), 8),
    ("znb", @lzw.Format::unix_compress(block_mode=false), 8),
  ]
}

///|
/// The inputs, by name: the GIF sets take their bytes' low bits.
fn inputs() -> Array[(String, Bytes)] {
  let out = []
  for n in [0, 1, 2, 100, 5000, 70000] {
    out.push(("text_\{n}", sample(n, n.to_uint64() + 1, text=true)))
  }
  out.push(("text_300000", sample(300000, 301, text=true)))
  out.push(("random_70000", sample(70000, 7, text=false)))
  out.push(("zeros_100000", Bytes::make(100000, b'\x00')))
  out.push(("period3_50000", Bytes::makei(50000, i => (i % 3).to_byte())))
  out
}

///|
/// One line a stream: name, set, the base64 of the input (masked for the
/// set) and that of the stream.
fn main {
  let sets = sets() catch { _ => abort("a format") }
  for item in inputs() {
    let (name, input) = item
    for set in sets {
      let (set_name, format, bits) = set
      let mask = (1 << bits) - 1
      let masked = Bytes::makei(input.length(), i => {
        (input[i].to_int() & mask).to_byte()
      })
      let stream = @lzw.compress(masked, format) catch {
        _ => abort("compress")
      }
      println(
        "\{name}\t\{set_name}\t\{@base64.encode(masked)}\t\{@base64.encode(stream)}",
      )
    }
  }
}
