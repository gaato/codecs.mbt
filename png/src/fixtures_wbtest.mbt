// Images built here, chunk by chunk, for the decoder's tests.

///|
fn type_bytes(name : String) -> Array[Byte] {
  [name[0].to_byte(), name[1].to_byte(), name[2].to_byte(), name[3].to_byte()]
}

///|
fn be32(n : UInt32) -> Array[Byte] {
  [(n >> 24).to_byte(), (n >> 16).to_byte(), (n >> 8).to_byte(), n.to_byte()]
}

///|
/// A chunk: its length, type, data and CRC, with `bad_crc` added to the
/// CRC.
fn chunk(name : String, data : Bytes, bad_crc~ : UInt32 = 0) -> Array[Byte] {
  let t = type_bytes(name)
  let crc = @crc32.update_bytes(@crc32.update(@crc32.INITIAL, t[:]), data[:])
  [
    ..be32(data.length().reinterpret_as_uint()),
    ..t,
    ..data,
    ..be32(crc + bad_crc),
  ]
}

///|
/// An IHDR chunk's data.
fn ihdr_data(
  width : UInt32,
  height : UInt32,
  bit_depth : Int32,
  color_type : Int32,
  interlace~ : Int32 = 0,
) -> Bytes {
  Bytes::from_array(
    [
      ..be32(width),
      ..be32(height),
      bit_depth.to_byte(),
      color_type.to_byte(),
      b'\x00',
      b'\x00',
      interlace.to_byte(),
    ],
  )
}

///|
/// The signature, then `chunks`.
fn png_of(chunks : Array[Array[Byte]]) -> Bytes {
  let out = [b'\x89', b'P', b'N', b'G', b'\r', b'\n', b'\x1a', b'\n']
  for c in chunks {
    out.append(c)
  }
  Bytes::from_array(out)
}

///|
/// A seeded generator of bytes.
priv struct Noise {
  mut state : UInt32
}

///|
fn Noise::byte(self : Noise) -> Byte {
  self.state = self.state * 1103515245 + 12345
  (self.state >> 16).to_byte()
}

///|
/// The Paeth predictor of 9.4, for the encoder's side.
fn predict_paeth(a : Int32, b : Int32, c : Int32) -> Int32 {
  let p = a + b - c
  let pa = (p - a).abs()
  let pb = (p - b).abs()
  let pc = (p - c).abs()
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// An image's rows, as they come out of the decoder (each pass's rows, in
/// order), and the filtered data that encodes them, before zlib: each row
/// with a filter type byte, the types going round 0 to 4.
priv struct Raw {
  rows : Bytes
  filtered : Bytes
}

///|
/// Random rows for an image of `width` x `height` with `bits` bits a pixel,
/// in Adam7's passes when `interlaced`.
fn raw_image(
  width : Int32,
  height : Int32,
  bits : Int32,
  interlaced~ : Bool = false,
  seed~ : UInt32 = 1,
) -> Raw {
  let noise = Noise::{ state: seed, }
  let rows = []
  let filtered = []
  let unit = (bits / 8).max(1)
  let mut kind = 0
  for pass in 0..<@rules.passes(interlaced) {
    let columns = @rules.pass_columns(interlaced, pass, width)
    let count = @rules.pass_rows(interlaced, pass, height)
    if columns == 0 || count == 0 {
      continue
    }
    let n = @rules.pass_row_bytes(columns, bits)
    let mut above = Array::make(n, b'\x00')
    for _ in 0..<count {
      let row = Array::makei(n, _ => noise.byte())
      rows.append(row)
      filtered.push(kind.to_byte())
      for i in 0..<n {
        let x = row[i].to_int()
        let a = if i >= unit { row[i - unit].to_int() } else { 0 }
        let b = above[i].to_int()
        let c = if i >= unit { above[i - unit].to_int() } else { 0 }
        let predicted = match kind {
          0 => 0
          1 => a
          2 => b
          3 => (a + b) / 2
          _ => predict_paeth(a, b, c)
        }
        filtered.push((x - predicted).to_byte())
      }
      above = row
      kind = (kind + 1) % 5
    }
  }
  { rows: Bytes::from_array(rows), filtered: Bytes::from_array(filtered), }
}

///|
/// A whole image of random rows: IHDR, a palette for indexed-color, the
/// image data in IDAT chunks of `idat_size` bytes, IEND.
fn image(
  width : Int32,
  height : Int32,
  bit_depth : Int32,
  color_type : Int32,
  interlaced~ : Bool = false,
  idat_size~ : Int32 = 1 << 20,
  seed~ : UInt32 = 1,
) -> (Bytes, Raw) {
  let bits = @rules.channels(color_type) * bit_depth
  let raw = raw_image(width, height, bits, interlaced~, seed~)
  let chunks = [
    chunk(
      "IHDR",
      ihdr_data(
        width.reinterpret_as_uint(),
        height.reinterpret_as_uint(),
        bit_depth,
        color_type,
        interlace=if interlaced { 1 } else { 0 },
      ),
    ),
  ]
  if color_type == 3 {
    chunks.push(chunk("PLTE", Bytes::makei(3 << bit_depth, i => i.to_byte())))
  }
  chunks.append(idat_chunks(@zlib.compress(raw.filtered), idat_size))
  chunks.push(chunk("IEND", b""))
  (png_of(chunks), raw)
}

///|
/// `data` in IDAT chunks of at most `size` bytes.
fn idat_chunks(data : Bytes, size : Int32) -> Array[Array[Byte]] {
  let out = []
  let mut at = 0
  while at < data.length() || out.is_empty() {
    let end = (at + size).min(data.length())
    out.push(chunk("IDAT", data[at:end].to_owned()))
    at = end
  }
  out
}

///|
/// What a run of a decoder showed: the rows' bytes, its answers in order
/// (`Rows` with its pass, first row and count), the error that ended it,
/// and the input it consumed.
priv struct Run {
  output : Bytes
  answers : Array[String]
  error : (@codec.ErrorKind, String)?
  consumed : Int32
  peak_memory : Int32
}

///|
/// Runs `decoder` over `input` in chunks of `chunk` bytes, with `room` bytes
/// of output a step, or `room_needed` when that is more, checking after every step what any image decoder must
/// keep: counts within what the step was given, writing only on `Rows` and
/// `Metadata` (whose blocks are part of the output),
/// `NeedMoreInput` with every byte consumed, and an error that sticks.
fn run(
  decoder : Decoder,
  input : Bytes,
  chunk~ : Int32 = 1 << 20,
  room~ : Int32 = 1 << 16,
  stop_at_done~ : Bool = true,
) -> Run raise {
  let output = Buffer()
  let answers = []
  let mut pos = 0
  let mut pending = input[0:0]
  let mut peak = decoder.memory_usage()
  for steps = 0; steps < 10_000_000; steps = steps + 1 {
    if pending.length() == 0 && pos < input.length() {
      let next = (pos + chunk).min(input.length())
      pending = input[pos:next]
      pos = next
    }
    let end = pos == input.length()
    let out = FixedArray::make(room.max(decoder.room_needed()), b'\x00')
    let status = decoder.step(pending, out.mut_view(), end~) catch {
      CodecError(kind, message) => {
        if decoder.last_produced() != 0 {
          fail("a step that raised wrote \{decoder.last_produced()} bytes")
        }
        pending = pending[decoder.last_consumed():]
        let again = try decoder.step(pending, out.mut_view(), end~) catch {
          CodecError(next, _) => Some(next)
        } noraise {
          _ => None
        }
        if again != Some(kind) || decoder.last_consumed() != 0 {
          fail("the error did not stick")
        }
        return {
          output: output.to_bytes(),
          answers,
          error: Some((kind, message)),
          consumed: pos - pending.length(),
          peak_memory: peak,
        }
      }
    }
    let consumed = decoder.last_consumed()
    let produced = decoder.last_produced()
    if consumed < 0 ||
      consumed > pending.length() ||
      produced < 0 ||
      produced > out.length() {
      fail(
        "consumed \{consumed} of \{pending.length()}, produced \{produced} into \{out.length()}",
      )
    }
    if produced != 0 && !(status is (Rows | Metadata)) {
      fail("\{@debug.to_string(status)} wrote \{produced} bytes")
    }
    peak = peak.max(decoder.memory_usage())
    output.write_bytes(Bytes::from_array(out[:produced]))
    pending = pending[consumed:]
    match status {
      Rows => {
        if produced != decoder.rows_count() * decoder.row_bytes() {
          fail("Rows wrote \{produced} bytes")
        }
        answers.push(
          "Rows \{decoder.pass()} \{decoder.rows_first()}+\{decoder.rows_count()}",
        )
      }
      Metadata => answers.push("Metadata \{decoder.metadata_type()}")
      NeedMoreInput => {
        if pending.length() != 0 || end {
          fail("NeedMoreInput with \{pending.length()} bytes left, end \{end}")
        }
        answers.push("NeedMoreInput")
      }
      Done => {
        answers.push("Done")
        if stop_at_done {
          return {
            output: output.to_bytes(),
            answers,
            error: None,
            consumed: pos - pending.length(),
            peak_memory: peak,
          }
        }
      }
      NeedMoreOutput => {
        if consumed == 0 {
          fail(
            "NeedMoreOutput with \{out.length()} bytes of room for a row of \{decoder.room_needed()}",
          )
        }
        answers.push("NeedMoreOutput")
      }
      other => answers.push(@debug.to_string(other))
    }
  }
  fail("no end")
}

///|
/// The answers, but `NeedMoreInput`, on one line.
fn outline(run : Run) -> String {
  let lines = []
  for answer in run.answers {
    if answer == "NeedMoreInput" {
      continue
    }
    lines.push(answer)
  }
  lines.join(" ")
}
