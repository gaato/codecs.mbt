///|
/// Writes a stream bit by bit, least significant bit first.
priv struct BitWriter {
  out : Array[Byte]
  mut acc : Int32
  mut count : Int32
}

///|
fn BitWriter::new() -> BitWriter {
  { out: [], acc: 0, count: 0, }
}

///|
fn BitWriter::bits(self : BitWriter, n : Int32, value : Int32) -> BitWriter {
  for i in 0..<n {
    self.acc = self.acc | (((value >> i) & 1) << self.count)
    self.count += 1
    if self.count == 8 {
      self.out.push(self.acc.to_byte())
      self.acc = 0
      self.count = 0
    }
  }
  self
}

///|
/// The stream so far, zero-padded to a whole byte.
fn BitWriter::finish(self : BitWriter) -> Bytes {
  let out = self.out.copy()
  if self.count > 0 {
    out.push(self.acc.to_byte())
  }
  Bytes::from_array(out)
}

///|
/// WBITS = 16, then the header of a last, compressed meta-block of `mlen`
/// bytes.
fn BitWriter::last_meta(self : BitWriter, mlen : Int32) -> BitWriter {
  self.bits(1, 0).bits(1, 1).bits(1, 0).bits(2, 0).bits(16, mlen - 1)
}

///|
/// A simple prefix code of one symbol: it takes no bits.
fn BitWriter::one_symbol(
  self : BitWriter,
  alphabet_bits : Int32,
  symbol : Int32,
) -> BitWriter {
  self.bits(2, 1).bits(2, 0).bits(alphabet_bits, symbol)
}

///|
/// One block type per category, NPOSTFIX = NDIRECT = 0, LSB6 literals, one
/// literal and one distance tree.
fn BitWriter::plain_header(self : BitWriter) -> BitWriter {
  self.bits(3, 0).bits(2, 0).bits(4, 0).bits(2, 0).bits(2, 0)
}

///|
/// A meta-block whose literal, command and distance codes each have one
/// symbol, so commands take only their extra bits.
fn BitWriter::fixed_commands(
  self : BitWriter,
  mlen~ : Int32,
  literal~ : Int32,
  command~ : Int32,
  distance~ : Int32,
) -> BitWriter {
  self
  .last_meta(mlen)
  .plain_header()
  .one_symbol(8, literal)
  .one_symbol(10, command)
  .one_symbol(6, distance)
}

///|
/// The compressed header up to the literal code, which `code` writes.
fn literal_code(code : (BitWriter) -> BitWriter) -> Bytes {
  code(BitWriter::new().last_meta(4).plain_header()).finish()
}

///|
/// The fixed code of code length code lengths: value `v` (section 3.5).
fn BitWriter::cl_length(self : BitWriter, v : Int32) -> BitWriter {
  match v {
    0 => self.bits(2, 0)
    1 => self.bits(4, 7)
    _ => abort("unused in these tests")
  }
}

///|
test "streams built here decode" {
  // Insert "a", copy 2 from distance 1 (code 16, one extra bit).
  let aaa = BitWriter::new()
    .fixed_commands(mlen=3, literal='a', command=136, distance=16)
    .bits(1, 0)
    .finish()
  inspect(@utf8.decode(decompress(aaa)), content="aaa")
  // A dictionary word: "time", word 0 of length 4, identity transform.
  let word = BitWriter::new()
    .fixed_commands(mlen=4, literal=0, command=130, distance=16)
    .bits(1, 0)
    .finish()
  inspect(@utf8.decode(decompress(word)), content="time")
  // Three literal block types; each switch names type 2 explicitly
  // (block type code 4), so the meta-block's commands read one switch per
  // literal after the first.
  let switches = BitWriter::new()
    .last_meta(3)
    .bits(1, 1)
    .bits(3, 1)
    .bits(1, 0)
    .one_symbol(3, 4)
    .one_symbol(5, 0)
    .bits(2, 0)
    .bits(2, 0)
    .bits(2, 0)
    .bits(4, 0)
    .bits(6, 0)
    .bits(2, 0)
    .one_symbol(8, 'a')
    .one_symbol(10, 152)
    .one_symbol(6, 0)
    .bits(4, 0)
    .finish()
  inspect(@utf8.decode(decompress(switches)), content="aaa")
  // NDIRECT = 4: distance code 16 is the direct distance 1.
  let direct = BitWriter::new()
    .last_meta(3)
    .bits(3, 0)
    .bits(2, 0)
    .bits(4, 4)
    .bits(2, 0)
    .bits(2, 0)
    .one_symbol(8, 'a')
    .one_symbol(10, 136)
    .one_symbol(7, 16)
    .finish()
  inspect(@utf8.decode(decompress(direct)), content="aaa")
  // The MSB6 context mode with two literal trees, "a" and "b": context
  // p1 >> 2 is 0 at the start and 24 after "a" or "b", which the map sends
  // to tree 1.
  let msb6 = BitWriter::new()
    .last_meta(3)
    .bits(3, 0)
    .bits(2, 0)
    .bits(4, 0)
    .bits(2, 1)
    .bits(1, 1)
    .bits(3, 0)
    .bits(1, 0)
    .bits(2, 1)
    .bits(2, 1)
    .bits(1, 0)
    .bits(1, 1)
    .bits(24, 0)
    .bits(1, 1)
    .bits(39, 0)
    .bits(1, 0)
    .bits(1, 0)
    .one_symbol(8, 'a')
    .one_symbol(8, 'b')
    .one_symbol(10, 152)
    .one_symbol(6, 0)
    .finish()
  inspect(@utf8.decode(decompress(msb6)), content="abb")
}

///|
test "malformed streams raise the error the RFC calls for" {
  let cases : Array[(String, Bytes, Int32)] = [
    (
      "large-window header",
      BitWriter::new().bits(1, 1).bits(3, 0).bits(3, 1).finish(),
      24,
    ),
    (
      "window over max_window_bits",
      BitWriter::new().bits(1, 1).bits(3, 7).finish(),
      22,
    ),
    (
      "reserved metadata bit",
      BitWriter::new().bits(2, 0).bits(2, 3).bits(1, 1).finish(),
      24,
    ),
    (
      "metadata length with a zero last byte",
      BitWriter::new()
      .bits(2, 0)
      .bits(2, 3)
      .bits(1, 0)
      .bits(2, 2)
      .bits(8, 5)
      .bits(8, 0)
      .finish(),
      24,
    ),
    (
      "meta-block length with a zero last nibble",
      BitWriter::new().bits(2, 0).bits(2, 1).bits(20, 0).finish(),
      24,
    ),
    (
      "padding before an uncompressed meta-block",
      BitWriter::new()
      .bits(2, 0)
      .bits(2, 0)
      .bits(16, 0)
      .bits(1, 1)
      .bits(3, 7)
      .finish(),
      24,
    ),
    (
      "padding after the last meta-block",
      BitWriter::new().bits(1, 0).bits(2, 3).bits(1, 1).finish(),
      24,
    ),
    (
      "simple code symbol past the alphabet",
      BitWriter::new()
      .last_meta(4)
      .plain_header()
      .one_symbol(8, 0)
      .one_symbol(10, 1000)
      .finish(),
      24,
    ),
    (
      "simple code with a repeated symbol",
      literal_code(w => w.bits(2, 1).bits(2, 1).bits(8, 97).bits(8, 97)),
      24,
    ),
    (
      "code length code with no lengths",
      literal_code(w => w.bits(2, 0).bits(36, 0)),
      24,
    ),
    (
      "incomplete prefix code",
      literal_code(w => {
        // Code length codes for lengths 1 and 0, one bit each.
        let w = w
          .bits(2, 0)
          .cl_length(1)
          .cl_length(0)
          .cl_length(0)
          .cl_length(0)
          .cl_length(1)
        // Symbol 0 gets length 1, every other symbol length 0.
        let w = w.bits(1, 1)
        for _ in 0..<255 {
          w.bits(1, 0) |> ignore
        }
        w
      }),
      24,
    ),
    (
      "code length repeat past the alphabet",
      literal_code(w => {
        // Code length codes for length 1 and the zero repeat, one bit each.
        let w = w.bits(2, 0).cl_length(1)
        for _ in 0..<5 {
          w.cl_length(0) |> ignore
        }
        // Zero repeats of 10, then 64 more, then 512 more.
        w
        .cl_length(1)
        .bits(1, 1)
        .bits(3, 7)
        .bits(1, 1)
        .bits(3, 7)
        .bits(1, 1)
        .bits(3, 7)
      }),
      24,
    ),
    (
      "context map run past its end",
      BitWriter::new()
      .last_meta(4)
      .bits(3, 0)
      .bits(2, 0)
      .bits(4, 0)
      .bits(2, 0)
      // NTREESL = 2, RLEMAX = 6, a code of the one symbol 6, run 64 + 1.
      .bits(1, 1)
      .bits(3, 0)
      .bits(1, 1)
      .bits(4, 5)
      .one_symbol(3, 6)
      .bits(6, 1)
      .finish(),
      24,
    ),
    (
      "insert past the end of the meta-block",
      BitWriter::new()
      .fixed_commands(mlen=1, literal=0, command=144, distance=16)
      .finish(),
      24,
    ),
    (
      "copy past the end of the meta-block",
      BitWriter::new()
      .fixed_commands(mlen=3, literal=0, command=138, distance=16)
      .bits(1, 0)
      .finish(),
      24,
    ),
    (
      "distance below one",
      BitWriter::new()
      .last_meta(10)
      .plain_header()
      .one_symbol(8, 0)
      .one_symbol(10, 136)
      // Distance codes 4 (last - 1) and 16, one bit each.
      .bits(2, 1)
      .bits(2, 1)
      .bits(6, 4)
      .bits(6, 16)
      // Distance 1, then last - 1 = 0.
      .bits(1, 1)
      .bits(1, 0)
      .bits(1, 0)
      .finish(),
      24,
    ),
    (
      "dictionary reference of length 2",
      BitWriter::new()
      .fixed_commands(mlen=5, literal=0, command=128, distance=16)
      .bits(1, 0)
      .finish(),
      24,
    ),
    (
      "dictionary transform 127",
      BitWriter::new()
      .fixed_commands(mlen=5, literal=0, command=130, distance=46)
      .bits(16, 0)
      .finish(),
      24,
    ),
    (
      "dictionary word past the end of the meta-block",
      BitWriter::new()
      .fixed_commands(mlen=3, literal=0, command=130, distance=16)
      .bits(1, 0)
      .finish(),
      24,
    ),
    ("data after the end", b"\x06\x00", 24),
  ]
  let results = cases.map(c => {
    let (name, input, max_window_bits) = c
    let outcome = try decompress(input, max_window_bits~) catch {
      BrotliError(kind, message) => "\{Repr(kind)}: \{message}"
    } noraise {
      _ => "decoded"
    }
    "\{name} -> \{outcome}"
  })
  debug_inspect(
    results,
    content=(
      #|[
      #|  "large-window header -> Corrupt: large-window streams are not RFC 7932",
      #|  "window over max_window_bits -> WindowTooLarge: the stream needs a 16777216-byte window, over the limit of 4194304",
      #|  "reserved metadata bit -> Corrupt: reserved bit set",
      #|  "metadata length with a zero last byte -> Corrupt: metadata length has a needless zero byte",
      #|  "meta-block length with a zero last nibble -> Corrupt: meta-block length has a needless zero nibble",
      #|  "padding before an uncompressed meta-block -> Corrupt: non-zero padding bits",
      #|  "padding after the last meta-block -> Corrupt: non-zero padding bits",
      #|  "simple code symbol past the alphabet -> Corrupt: simple prefix code symbol out of range",
      #|  "simple code with a repeated symbol -> Corrupt: simple prefix code repeats a symbol",
      #|  "code length code with no lengths -> Corrupt: invalid code length code",
      #|  "incomplete prefix code -> Corrupt: incomplete or oversubscribed prefix code",
      #|  "code length repeat past the alphabet -> Corrupt: code length repeat past the alphabet",
      #|  "context map run past its end -> Corrupt: context map run past its end",
      #|  "insert past the end of the meta-block -> Corrupt: insert past the end of the meta-block",
      #|  "copy past the end of the meta-block -> Corrupt: copy past the end of the meta-block",
      #|  "distance below one -> Corrupt: distance below one",
      #|  "dictionary reference of length 2 -> Corrupt: distance beyond the window with no dictionary word",
      #|  "dictionary transform 127 -> Corrupt: distance beyond the window and the dictionary",
      #|  "dictionary word past the end of the meta-block -> Corrupt: dictionary word past the end of the meta-block",
      #|  "data after the end -> TrailingData: data after the end of the stream",
      #|]
    ),
  )
}
