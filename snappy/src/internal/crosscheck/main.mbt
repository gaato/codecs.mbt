///|
/// Bytes from a seeded LCG: text from a small vocabulary, or noise.
fn sample(n : Int32, seed : UInt64, text~ : Bool) -> Bytes {
  let words = [
    "the ", "snappy ", "frame ", "chunk ", "of ", "copy ", "literal ", "and ", "a ",
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
/// The inputs, by name.
fn inputs() -> Array[(String, Bytes)] {
  let out = []
  for n in [0, 1, 14, 15, 16, 1000, 65535, 65536, 65537, 300000] {
    out.push(("text_\{n}", sample(n, n.to_uint64() + 1, text=true)))
  }
  out.push(("random_70000", sample(70000, 7, text=false)))
  out.push(("zeros_100000", Bytes::make(100000, b'\x00')))
  out.push(("period3_50000", Bytes::makei(50000, i => (i % 3).to_byte())))
  let unit = sample(1000, 11, text=false)
  out.push(("period1000_200000", Bytes::makei(200000, i => unit[i % 1000])))
  out
}

///|
/// `input` framed with a flush every `every` bytes.
fn flushed(input : Bytes, every : Int32) -> Bytes {
  let e = @snappy.Encoder()
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
    let status = e.step(input[pos:end], slice.mut_view(), action~)
    out.write_bytesview(Bytes::from_array(slice[:e.last_produced()])[:])
    if status is Done {
      return out.to_bytes()
    }
    pos = end
  }
}

///|
/// One line a stream: name, format (snappy-raw or snappy-frame), the
/// base64 of the input and that of the stream.
fn main {
  for item in inputs() {
    let (name, input) = item
    let b64 = @base64.encode(input)
    let raw = @snappy.compress_raw(input)
    println("\{name}\tsnappy-raw\t\{b64}\t\{@base64.encode(raw)}")
    let frame = @snappy.compress(input)
    println("\{name}\tsnappy-frame\t\{b64}\t\{@base64.encode(frame)}")
    if input.length() > 20000 {
      let f = flushed(input, 10000)
      println("\{name}_flushed\tsnappy-frame\t\{b64}\t\{@base64.encode(f)}")
    }
  }
}
