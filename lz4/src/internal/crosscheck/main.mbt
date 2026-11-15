///|
/// Bytes from a seeded LCG: text from a small vocabulary, or noise.
fn sample(n : Int32, seed : UInt64, text~ : Bool) -> Bytes {
  let words = [
    "the ", "lz4 ", "frame ", "block ", "of ", "match ", "literal ", "and ", "a ",
    "stream ", "\n",
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
/// The dictionary the dictionary sets use.
fn dictionary() -> Bytes {
  sample(20000, 99, text=true)
}

///|
/// The inputs, by name, and the sets each is encoded with: every set for
/// the small ones and one of 70,000 bytes, which spans two 64 KiB blocks;
/// for the rest, the sets their size is there for (the largest block the
/// small table serves, 65,546 bytes, and the smallest the large one does;
/// linked blocks over many; incompressible blocks, stored).
fn inputs() -> Array[(String, Bytes, Array[String])] {
  let all = [
    "b4i", "b4d", "b7i", "b5ix", "fast9", "b4i_dict", "b4d_dict", "block", "block_dict",
    "legacy",
  ]
  let out = []
  for n in [0, 1, 12, 13, 14, 1000, 70000] {
    out.push(("text_\{n}", sample(n, n.to_uint64() + 1, text=true), all))
  }
  for n in [65546, 65547] {
    out.push(
      ("text_\{n}", sample(n, n.to_uint64() + 1, text=true), ["b7i", "block"]),
    )
  }
  out.push(("text_150000", sample(150000, 151, text=true), ["b4d", "b7i"]))
  out.push(("random_70000", sample(70000, 7, text=false), ["b4i"]))
  out.push(("zeros_100000", Bytes::make(100000, b'\x00'), ["b4i", "b4d"]))
  out.push(("period3_50000", Bytes::makei(50000, i => (i % 3).to_byte()), all))
  let unit = sample(1000, 11, text=false)
  out.push(
    ("period1000_200000", Bytes::makei(200000, i => unit[i % 1000]), ["b4d"]),
  )
  // A match at the first byte, which only a cleared table's entries find.
  out.push(
    ("abcdXabcdY_100", b"abcdXabcdY".repeat(10), ["b4i", "b4d", "block"]),
  )
  out
}

///|
/// What gaato/lz4 writes for `input` in `set`, or None for a set it does
/// not write (legacy frames).
fn encode(set : String, input : Bytes, dict : Bytes) -> Bytes? {
  match set {
    "b4i" => Some(@lz4.compress(input, linked=false))
    "b4d" => Some(@lz4.compress(input, linked=true))
    "b7i" => Some(@lz4.compress(input, block_size=Max4MiB, linked=false))
    "b5ix" => {
      let e = @lz4.Encoder(
        block_size=Max256KiB,
        linked=false,
        block_checksum=true,
        content_size=input.length().to_int64(),
      )
      Some(run(e, input, input.length() + 1))
    }
    "fast9" =>
      Some(@lz4.compress(input, linked=false, checksum=false, acceleration=9))
    "b4i_dict" =>
      Some(@lz4.compress(input, linked=false, dictionary=dict, dictionary_id=7))
    "b4d_dict" => Some(@lz4.compress(input, linked=true, dictionary=dict))
    "block" => Some(@lz4.compress_block(input))
    "block_dict" => Some(@lz4.compress_block(input, dictionary=dict))
    _ => None
  }
}

///|
/// `input` through `e`, with a flush every `every` bytes.
fn run(e : @lz4.Encoder, input : Bytes, every : Int32) -> Bytes {
  let out = Buffer()
  let slice = FixedArray::make(1 << 17, b'\x00')
  let mut pos = 0
  for ;; {
    let end = (pos + every).min(input.length())
    let action : @codec_bytes.EncodeAction = if end == input.length() {
      Finish
    } else {
      Flush
    }
    let status = e.step(input[pos:end], slice.mut_view(), action~) catch {
      _ => abort("the encoder raised")
    }
    out.write_bytesview(Bytes::from_array(slice[:e.last_produced()])[:])
    pos += e.last_consumed()
    if status is Done {
      return out.to_bytes()
    }
  }
}

///|
/// One line for the dictionary, then one a stream: name, set, the base64 of
/// the input and that of the stream ("-" for a set gaato/lz4 does not
/// write). Inputs over 20,000 bytes also come flushed every 10,000, in
/// linked blocks (set "flushed").
fn main {
  let dict = dictionary()
  println("dictionary\t-\t\{@base64.encode(dict)}\t-")
  for item in inputs() {
    let (name, input, sets) = item
    let b64 = @base64.encode(input)
    for set in sets {
      let stream = match encode(set, input, dict) {
        Some(s) => @base64.encode(s)
        None => "-"
      }
      println("\{name}\t\{set}\t\{b64}\t\{stream}")
    }
    if input.length() > 20000 {
      let f = run(@lz4.Encoder(), input, 10000)
      println("\{name}\tflushed\t\{b64}\t\{@base64.encode(f)}")
    }
  }
}
