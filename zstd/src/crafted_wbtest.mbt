// Streams built by hand, byte by byte and bit by bit, for what the
// reference encoder never emits: every refusal RFC 8878 calls for, and
// headers at the edges of their ranges.

///|
/// `n` little-endian bytes of `v`.
fn le(v : UInt64, n : Int32) -> Array[Byte] {
  Array::makei(n, i => (v >> (8 * i)).to_byte())
}

///|
/// A frame: the magic number, `header` (descriptor and its fields), then
/// `rest` (blocks and checksum).
fn frame(header : Array[Byte], rest : Array[Byte]) -> Bytes {
  Bytes::from_array([..le(0xFD2FB528, 4), ..header, ..rest])
}

///|
/// A frame header with no content size, checksum or dictionary, and a
/// window of 1 KiB (0x00) or 128 KiB (0x38).
fn plain(window : Byte) -> Array[Byte] {
  [b'\x00', window]
}

///|
/// A block of `kind` (0 raw, 1 RLE, 2 compressed) holding `content`.
/// `size` replaces the header's size field (an RLE block's repeat count).
fn block(
  kind : Int32,
  content : Array[Byte],
  last~ : Bool = true,
  size? : Int32,
) -> Array[Byte] {
  let size = size.unwrap_or(content.length())
  let header = (if last { 1 } else { 0 }) | (kind << 1) | (size << 3)
  [..le(header.to_uint64(), 3), ..content]
}

///|
/// A bitstream that `BackwardBits` reads as `fields`, `(value, bits)` pairs
/// in reading order, then exactly used up.
fn backward(fields : Array[(Int32, Int32)]) -> Array[Byte] {
  let total = fields.fold(init=0, (sum, f) => sum + f.1)
  let bits = FixedArray::make(total + 1, false)
  let mut top = total
  for f in fields {
    let (value, n) = f
    for i in 0..<n {
      bits[top - n + i] = ((value >> i) & 1) != 0
    }
    top -= n
  }
  bits[total] = true
  Array::makei((total + 8) / 8, i => {
    let mut b = 0
    for j in 0..<8 {
      if 8 * i + j <= total && bits[8 * i + j] {
        b = b | (1 << j)
      }
    }
    b.to_byte()
  })
}

///|
/// A table description (RFC 8878 section 4.1.1) of `probs` at accuracy
/// `log`, as the reference encoder writes it; a zero is followed by a
/// repeat flag of 0. `extra` bits are appended as given.
fn description(
  log : Int32,
  probs : Array[Int32],
  extra~ : Array[(Int32, Int32)] = [],
) -> Array[Byte] {
  let fields = [(log - 5, 4)]
  let mut remaining = 1 << log
  for prob in probs {
    let value = prob + 1
    let width = 32 - (remaining + 1).clz()
    let threshold = (1 << width) - 1 - (remaining + 1)
    if value < threshold {
      fields.push((value, width - 1))
    } else if value < 1 << (width - 1) {
      fields.push((value, width))
    } else {
      fields.push((value + threshold, width))
    }
    remaining -= if prob < 0 { 1 } else { prob }
    if prob == 0 {
      fields.push((0, 2))
    }
  }
  fields.append(extra)
  let total = fields.fold(init=0, (sum, f) => sum + f.1)
  let out = Array::make((total + 7) / 8, b'\x00')
  let mut pos = 0
  for f in fields {
    let (value, n) = f
    for i in 0..<n {
      if ((value >> i) & 1) != 0 {
        out[(pos + i) / 8] = out[(pos + i) / 8] |
          (1 << ((pos + i) % 8)).to_byte()
      }
    }
    pos += n
  }
  out
}

///|
/// A raw literals section holding `literals`.
fn raw_literals(literals : Array[Byte]) -> Array[Byte] {
  let n = literals.length()
  let header = if n < 32 {
    [(n << 3).to_byte()]
  } else {
    [(((n & 15) << 4) | 4).to_byte(), (n >> 4).to_byte()]
  }
  [..header, ..literals]
}

///|
/// A compressed literals header: `kind` 2 (with a tree) or 3 (treeless),
/// `size_format` 0 to 3, and both sizes.
fn huffman_header(
  kind : Int32,
  size_format : Int32,
  regenerated : Int32,
  compressed : Int32,
) -> Array[Byte] {
  let (bytes, width) = match size_format {
    0 | 1 => (3, 10)
    2 => (4, 14)
    _ => (5, 18)
  }
  let fields = kind.to_uint64() |
    (size_format.to_uint64() << 2) |
    (regenerated.to_uint64() << 4) |
    (compressed.to_uint64() << (4 + width))
  le(fields, bytes)
}

///|
/// The first state of `table` that gives `symbol`.
fn state_of(table : Fse, symbol : Int32) -> Int32 {
  for i in 0..<(1 << table.log) {
    if table.symbol_of(i) == symbol {
      return i
    }
  }
  abort("no state for \{symbol}")
}

///|
/// What `decompress` makes of `input`: an error kind and message, or the
/// decoded length.
fn outcome(input : Bytes, max_window_bits~ : Int32 = 27) -> String {
  try decompress(input, max_window_bits~) catch {
    CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    out => "decoded \{out.length()}"
  }
}

///|
/// A compressed block in a 1 KiB-window frame.
fn compressed(content : Array[Byte]) -> Bytes {
  frame(plain(b'\x00'), block(2, content))
}

///|
test "frame headers: reserved and unused bits, dictionaries" {
  let empty = block(0, [])
  inspect(
    outcome(frame([b'\x08', b'\x00'], empty)),
    content="Corrupt: the frame header's reserved bit is set",
  )
  // The unused bit is ignored; a dictionary ID of 0 names no dictionary.
  inspect(outcome(frame([b'\x10', b'\x00'], empty)), content="decoded 0")
  inspect(
    outcome(frame([b'\x03', b'\x00', ..le(0, 4)], empty)),
    content="decoded 0",
  )
  inspect(
    outcome(frame([b'\x01', b'\x00', b'\x07'], empty)),
    content=(
      #|DictionaryRequired(Some(7)): the frame needs dictionary 7
    ),
  )
  inspect(
    outcome(frame([b'\x02', b'\x00', ..le(0x1234, 2)], empty)),
    content=(
      #|DictionaryRequired(Some(4660)): the frame needs dictionary 4660
    ),
  )
  inspect(
    outcome(frame([b'\x03', b'\x00', ..le(0xFFFFFFFF, 4)], empty)),
    content=(
      #|DictionaryRequired(Some(4294967295)): the frame needs dictionary 4294967295
    ),
  )
}

///|
test "windows are refused before anything is allocated" {
  // The largest window descriptor: 2^41 + 7 * 2^38 bytes.
  let decoder = Decoder(max_window_bits=30)
  let huge = frame([b'\x00', b'\xFF'], block(0, []))
  let refused = try
    decoder.step_into(huge, FixedArray::make(16, b'\x00'), end=false)
  catch {
    CodecError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => fail("accepted")
  }
  inspect(
    refused,
    content=(
      #|LimitExceeded({ resource: Memory, needed: Some(4123168604160), limit: 1073741824 }): the frame needs a 4123168604160-byte window, over the 1073741824-byte limit
    ),
  )
  assert_eq(decoder.ring.length(), 0)
  assert_eq(decoder.block.length(), 0)
  // A single-segment frame's window is its content size: up to 2^64 - 1.
  inspect(
    outcome(
      frame([b'\xE0', ..le(1UL << 63, 8)], block(0, [])),
      max_window_bits=30,
    ),
    content=(
      #|LimitExceeded(
      #|  {
      #|    resource: Memory,
      #|    needed: Some(9223372036854775808),
      #|    limit: 1073741824,
      #|  },
      #|): the frame needs a 9223372036854775808-byte window, over the 1073741824-byte limit
    ),
  )
  // Exactly 1 << max_window_bits is accepted.
  inspect(
    outcome(
      frame([b'\xA0', ..le(1 << 20, 4)], block(1, [b'a'], size=0)),
      max_window_bits=20,
    ),
    content="Corrupt: the frame holds less than its declared content size",
  )
}

///|
test "content sizes: every field size, and frames that disagree with theirs" {
  // One byte, single segment; two bytes add 256; a window of 0.
  inspect(
    outcome(frame([b'\x20', b'\x03'], block(0, [b'a', b'b', b'c']))),
    content="decoded 3",
  )
  inspect(
    outcome(frame([b'\x60', ..le(0, 2)], block(1, [b'z'], size=256))),
    content="decoded 256",
  )
  inspect(outcome(frame([b'\x20', b'\x00'], block(0, []))), content="decoded 0")
  inspect(
    outcome(frame([b'\x80', b'\x00', ..le(2, 4)], block(0, [b'a', b'b']))),
    content="decoded 2",
  )
  inspect(
    outcome(frame([b'\x20', b'\x05'], block(0, [b'a', b'b', b'c']))),
    content="Corrupt: the frame holds less than its declared content size",
  )
  inspect(
    outcome(
      frame(
        [b'\x20', b'\x05'],
        [
          ..block(0, [b'a', b'b', b'c', b'd', b'e'], last=false),
          ..block(0, [b'f']),
        ],
      ),
    ),
    content="Corrupt: the frame holds more than its declared content size",
  )
  // A window of 0 takes no block with content.
  inspect(
    outcome(frame([b'\x20', b'\x00'], block(0, [b'a']))),
    content="Corrupt: a raw block larger than the block limit",
  )
}

///|
test "content checksums are checked" {
  let data = [b'a', b'b', b'c']
  let h = @xxhash.Xxh64()
  h.update_bytes(Bytes::from_array(data))
  let digest = h.digest()
  let good = frame([b'\x04', b'\x00'], [..block(0, data), ..le(digest, 4)])
  inspect(outcome(good), content="decoded 3")
  let bad = frame([b'\x04', b'\x00'], [..block(0, data), ..le(digest ^ 1, 4)])
  inspect(
    outcome(bad),
    content="ChecksumMismatch: the frame's content checksum does not match",
  )
}

///|
test "block headers: the reserved type and the block limit" {
  let header = plain(b'\x00')
  inspect(
    outcome(frame(header, block(3, []))),
    content="Corrupt: a block of the reserved type",
  )
  let big = Array::make(1025, b'\x00')
  inspect(
    outcome(frame(header, block(0, big))),
    content="Corrupt: a raw block larger than the block limit",
  )
  inspect(
    outcome(frame(header, block(1, [b'a'], size=1025))),
    content="Corrupt: an RLE block larger than the block limit",
  )
  inspect(
    outcome(frame(header, block(2, big))),
    content="Corrupt: a compressed block larger than the block limit",
  )
  inspect(
    outcome(frame(header, block(2, []))),
    content="Corrupt: an empty compressed block",
  )
  // The limit is 1 KiB here and 128 KiB at most.
  inspect(
    outcome(frame(header, block(1, [b'a'], size=1024))),
    content="decoded 1024",
  )
  inspect(
    outcome(frame(plain(b'\x48'), block(1, [b'a'], size=131073))),
    content="Corrupt: an RLE block larger than the block limit",
  )
}

///|
test "skippable frames are skipped without being kept" {
  let skip = Bytes::from_array([..le(0x184D2A5F, 4), ..le(0xFFFFFFFF, 4), b'x'])
  inspect(outcome(skip), content="Truncated: the stream ends inside a frame")
  let decoder = Decoder()
  let out = FixedArray::make(16, b'\x00')
  debug_inspect(
    decoder.step_into(skip, out, end=false),
    content="NeedMoreInput",
  )
  inspect(decoder.last_consumed(), content="9")
  inspect(decoder.remaining, content="4294967294")
  assert_eq(decoder.block.length(), 0)
}

///|
test "literals sections cut short or out of range" {
  inspect(
    outcome(compressed([b'\x04'])),
    content="Corrupt: a literals header past its block",
  )
  inspect(
    outcome(compressed([b'\x0C', b'\x00'])),
    content="Corrupt: a literals header past its block",
  )
  inspect(
    outcome(compressed([b'\x0C', b'\x00', b'\x00'])),
    content="Corrupt: a compressed block without its sequences section",
  )
  inspect(
    outcome(compressed([(5 << 3).to_byte(), b'a', b'b'])),
    content="Corrupt: raw literals past their block",
  )
  inspect(
    outcome(compressed([(1 | (5 << 3)).to_byte()])),
    content="Corrupt: RLE literals past their block",
  )
  // 2000 literals in a block of at most 1 KiB.
  inspect(
    outcome(compressed([b'\x0D', ..le(2000 >> 4, 1), b'a', b'\x00'])),
    content="Corrupt: more literals than the block limit",
  )
  inspect(
    outcome(compressed([..huffman_header(2, 2, 2000, 3), b'\x00'])),
    content="Corrupt: more literals than the block limit",
  )
  inspect(
    outcome(compressed([..huffman_header(2, 0, 4, 30), b'\x00'])),
    content="Corrupt: compressed literals past their block",
  )
  inspect(
    outcome(compressed([..huffman_header(3, 0, 4, 1), b'\x80', b'\x00'])),
    content="Corrupt: treeless literals before any Huffman table",
  )
}

///|
test "Huffman tree descriptions" {
  inspect(
    outcome(compressed([..huffman_header(2, 0, 4, 0), b'\x00'])),
    content="Corrupt: a Huffman tree description runs past its section",
  )
  // 128 direct weights need 64 bytes.
  inspect(
    outcome(
      compressed([..huffman_header(2, 0, 4, 2), b'\xFF', b'\x11', b'\x00']),
    ),
    content="Corrupt: a Huffman tree description runs past its section",
  )
  inspect(
    outcome(compressed([..huffman_header(2, 0, 4, 1), b'\x00', b'\x00'])),
    content="Corrupt: a Huffman tree description runs past its section",
  )
  inspect(
    outcome(
      compressed([..huffman_header(2, 0, 4, 3), b'\x05', b'\x00', b'\x00']),
    ),
    content="Corrupt: a Huffman tree description runs past its section",
  )
  // One weight of 0: no symbol has a code.
  inspect(
    outcome(
      compressed([..huffman_header(2, 0, 4, 2), b'\x81', b'\x00', b'\x00']),
    ),
    content="Corrupt: a Huffman tree with one symbol",
  )
  inspect(
    outcome(
      compressed([..huffman_header(2, 0, 4, 2), b'\x81', b'\xC0', b'\x00']),
    ),
    content="Corrupt: a Huffman weight above 11",
  )
  // Weights 3 and 1 sum to 5: no single weight completes a tree of 8.
  inspect(
    outcome(
      compressed([..huffman_header(2, 0, 4, 2), b'\x81', b'\x31', b'\x00']),
    ),
    content="Corrupt: Huffman weights that do not complete a tree",
  )
  // One explicit weight of 2 and an implied 2: a tree, but none of weight 1.
  inspect(
    outcome(
      compressed(
        [..huffman_header(2, 0, 1, 3), b'\x80', b'\x20', b'\x02', b'\x00'],
      ),
    ),
    content="Corrupt: a Huffman tree with no weight of 1",
  )
  // An FSE weight table whose one symbol takes no bits per state: the
  // states never use up the stream.
  let table = description(5, [32])
  let weights = backward([(0, 5), (0, 5)])
  let size = table.length() + weights.length()
  inspect(
    outcome(
      compressed(
        [
          ..huffman_header(2, 0, 4, 1 + size),
          size.to_byte(),
          ..table,
          ..weights,
          b'\x00',
        ],
      ),
    ),
    content="Corrupt: more than 255 Huffman weights",
  )
  // Its initial states need more bits than the stream holds.
  let short = backward([(0, 3)])
  let size = table.length() + short.length()
  inspect(
    outcome(
      compressed(
        [
          ..huffman_header(2, 0, 4, 1 + size),
          size.to_byte(),
          ..table,
          ..short,
          b'\x00',
        ],
      ),
    ),
    content="Corrupt: Huffman weights without their initial states",
  )
}

///|
test "Huffman streams" {
  // Weights 1, 0 and the implied 1: symbols 0 and 2 have 1-bit codes.
  let tree = [b'\x81', b'\x10']
  let one = backward([(1, 1), (0, 1), (1, 1), (1, 1)])
  inspect(
    outcome(
      compressed(
        [..huffman_header(2, 0, 4, 2 + one.length()), ..tree, ..one, b'\x00'],
      ),
    ),
    content="decoded 4",
  )
  // One literal too many for the stream.
  inspect(
    outcome(
      compressed(
        [..huffman_header(2, 0, 5, 2 + one.length()), ..tree, ..one, b'\x00'],
      ),
    ),
    content="Corrupt: a Huffman stream that does not end with its literals",
  )
  inspect(
    outcome(
      compressed(
        [
          ..huffman_header(2, 1, 8, 2 + 5),
          ..tree,
          ..Array::make(5, b'\x01'),
          b'\x00',
        ],
      ),
    ),
    content="Corrupt: four Huffman streams in fewer than 10 bytes",
  )
  // A jump table pointing past the streams.
  inspect(
    outcome(
      compressed(
        [
          ..huffman_header(2, 1, 8, 2 + 10),
          ..tree,
          ..le(1, 2),
          ..le(1, 2),
          ..le(2, 2),
          ..Array::make(4, b'\x01'),
          b'\x00',
        ],
      ),
    ),
    content="Corrupt: a Huffman jump table past its streams",
  )
  // Four streams need at least 6 literals (RFC 8878 erratum 7297), whatever
  // the streams hold; the reference decoder rejects these too.
  for regenerated in [0, 1, 4, 5] {
    inspect(
      outcome(
        compressed(
          [
            ..huffman_header(2, 1, regenerated, 2 + 10),
            ..tree,
            ..le(1, 2),
            ..le(1, 2),
            ..le(1, 2),
            ..Array::make(4, b'\x01'),
            b'\x00',
          ],
        ),
      ),
      content="Corrupt: fewer than 6 literals in four Huffman streams",
    )
  }
}

///|
test "sequences section headers" {
  let none = raw_literals([])
  inspect(
    outcome(compressed([..none, b'\x00', b'\x00'])),
    content="Corrupt: bytes after a sequences section without sequences",
  )
  inspect(
    outcome(compressed([..none, b'\x80'])),
    content="Corrupt: a sequences header past its block",
  )
  inspect(
    outcome(compressed([..none, b'\xFF', b'\x00'])),
    content="Corrupt: a sequences header past its block",
  )
  inspect(
    outcome(compressed([..none, b'\x01'])),
    content="Corrupt: a sequences header past its block",
  )
  // 0x7F00 sequences, in the 3-byte form.
  inspect(
    outcome(compressed([..none, b'\xFF', b'\x00', b'\x00', b'\x03'])),
    content="Corrupt: the sequences header's reserved bits are set",
  )
  inspect(
    outcome(compressed([..none, b'\x01', b'\x40'])),
    content="Corrupt: an RLE literals lengths code past its block",
  )
  inspect(
    outcome(compressed([..none, b'\x01', b'\x40', b'\x24'])),
    content="Corrupt: an RLE literals lengths code out of range",
  )
  inspect(
    outcome(compressed([..none, b'\x01', b'\xC0', b'\x01'])),
    content="Corrupt: repeated literals lengths codes before any table",
  )
  inspect(
    outcome(compressed([..none, b'\x01', b'\x00'])),
    content="Corrupt: an empty bitstream",
  )
  inspect(
    outcome(compressed([..none, b'\x01', b'\x00', b'\x00'])),
    content="Corrupt: a bitstream without its end mark",
  )
}

///|
test "FSE table descriptions" {
  let none = raw_literals([])
  let fse_ll = (table : Array[Byte]) => {
    compressed([..none, b'\x01', b'\x80', ..table])
  }
  inspect(
    outcome(fse_ll(description(10, [1024]))),
    content="Corrupt: an FSE accuracy log above 9",
  )
  // 37 symbols of probability 1 out of 64: symbol 36 has no code.
  inspect(
    outcome(fse_ll(description(6, Array::make(37, 1)))),
    content="Corrupt: an FSE probability for a symbol out of range",
  )
  // Zeros repeated past the last code.
  inspect(
    outcome(
      fse_ll(description(5, [], extra=[(1, 5), ..Array::make(12, (3, 2))])),
    ),
    content="Corrupt: an FSE probability for a symbol out of range",
  )
  // A description cut short: in a value, then in a repeat flag.
  inspect(
    outcome(fse_ll(description(6, [1, 1]))),
    content="Corrupt: a table description runs past its section",
  )
  // Three values of 5 bits and a zero end on a byte; its flag is past it.
  let cut = description(5, [1, 1, 1, 0])
  inspect(cut.length(), content="4")
  inspect(
    outcome(fse_ll(cut[:3].to_owned())),
    content="Corrupt: a table description runs past its section",
  )
}

///|
test "sequences: offset codes, offsets and the block limit" {
  let none = raw_literals([])
  // An RLE offset code of 31.
  let stream = backward([
    (state_of(ll_predefined, 0), 6),
    (state_of(ml_predefined, 0), 6),
  ])
  inspect(
    outcome(compressed([..none, b'\x01', b'\x10', b'\x1F', ..stream])),
    content="Corrupt: an offset code above 30",
  )
  // Offset code 25, read in two parts: past anything decoded.
  let stream = backward([
    (state_of(ll_predefined, 0), 6),
    (state_of(of_predefined, 25), 5),
    (state_of(ml_predefined, 0), 6),
    (12345, 25),
  ])
  inspect(
    outcome(compressed([..none, b'\x01', b'\x00', ..stream])),
    content="Corrupt: an offset beyond the decoded data",
  )
  // 10 literals, a match of 1000 from 1 back, then 20 literals: past the
  // 1 KiB block limit of a 1 KiB window.
  let literals = Array::make(30, b'a')
  let stream = backward([
    (state_of(ll_predefined, 10), 6),
    (state_of(of_predefined, 2), 5),
    (state_of(ml_predefined, 45), 6),
    (0, 2),
    (1000 - 515, 9),
  ])
  inspect(
    outcome(compressed([..raw_literals(literals), b'\x01', b'\x00', ..stream])),
    content="Corrupt: a block that decodes past the block limit",
  )
  // The same in a 128 KiB window decodes.
  inspect(
    outcome(
      frame(
        plain(b'\x38'),
        block(2, [..raw_literals(literals), b'\x01', b'\x00', ..stream]),
      ),
    ),
    content="decoded 1030",
  )
  // A match past the limit.
  let stream = backward([
    (state_of(ll_predefined, 10), 6),
    (state_of(of_predefined, 2), 5),
    (state_of(ml_predefined, 46), 6),
    (0, 2),
    (0, 10),
  ])
  inspect(
    outcome(compressed([..raw_literals(literals), b'\x01', b'\x00', ..stream])),
    content="Corrupt: a block that decodes past the block limit",
  )
  // More literals than the section holds.
  let stream = backward([
    (state_of(ll_predefined, 31), 6),
    (state_of(of_predefined, 2), 5),
    (state_of(ml_predefined, 0), 6),
    (0, 2),
    (0, 12),
  ])
  inspect(
    outcome(compressed([..raw_literals(literals), b'\x01', b'\x00', ..stream])),
    content="Corrupt: a sequence with more literals than the block holds",
  )
  // Bits left over after the last sequence.
  let stream = backward([
    (state_of(ll_predefined, 10), 6),
    (state_of(of_predefined, 2), 5),
    (state_of(ml_predefined, 0), 6),
    (0, 2),
    (0, 3),
  ])
  inspect(
    outcome(compressed([..raw_literals(literals), b'\x01', b'\x00', ..stream])),
    content="Corrupt: a sequences bitstream that is not used up exactly",
  )
}
