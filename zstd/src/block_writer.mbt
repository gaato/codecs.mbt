// The encoder's frame and blocks (RFC 8878 section 3.1.1): the frame
// header, block headers, and the literals section of a compressed block.
// Every field is written least significant bit first by the bit writer,
// which is the little-endian order of the format's multi-byte fields.

///|
/// The literals section of a compressed block (section 3.1.1.3.1): its
/// literals as they are, one byte repeated, or Huffman-coded.
#valtype
priv enum LiteralsKind {
  LitRaw
  LitRle
  /// In one stream, or four after a jump table.
  LitHuffman(four~ : Bool)
  LitTreeless(four~ : Bool)
}

///|
/// How a literals section will be written: its size in bytes, header
/// included, and the bytes after its header.
/// Kept as a value so choosing a block allocates neither a plan nor its kind.
#valtype
priv struct LiteralsPlan {
  kind : LiteralsKind
  size : Int32
  payload : Int32
}

///|
/// Chooses and writes literals sections: the byte counts and the Huffman
/// coder they need.
priv struct LiteralsWriter {
  mut huffman : @huffenc.HuffmanEncoder
  mut previous : @huffenc.HuffmanEncoder
  mut previous_valid : Bool
  // The counts of each byte value in the literals, and, for four streams,
  // in each stream.
  counts : FixedArray[Int32]
  quarters : FixedArray[FixedArray[Int32]]
}

///|
fn LiteralsWriter::new() -> LiteralsWriter {
  {
    huffman: @huffenc.HuffmanEncoder(),
    previous: @huffenc.HuffmanEncoder(),
    previous_valid: false,
    counts: FixedArray::make(256, 0),
    quarters: FixedArray::makei(4, _ => FixedArray::make(256, 0)),
  }
}

///|
fn LiteralsWriter::reset(self : LiteralsWriter) -> Unit {
  self.previous_valid = false
}

///|
/// The bytes the writer holds: the Huffman coder and the counts.
fn LiteralsWriter::memory_usage(self : LiteralsWriter) -> Int32 {
  self.huffman.memory_usage() +
  self.previous.memory_usage() +
  4 * self.counts.length() +
  4 * 4 * self.quarters[0].length()
}

///|
/// Literals in one Huffman stream below this many, in four from it, as
/// zstd chooses: four streams decode faster and cost a 6-byte jump table
/// and up to three bytes of padding more.
const FOUR_STREAMS_FROM : Int32 = 256

///|
/// The smallest literals section for `data[start:start + len]` (at most a
/// block): raw, RLE when there is one byte value, or Huffman when it builds
/// a code. Ties go to the simpler kind. A Huffman plan leaves its code in
/// the writer for `write`.
fn LiteralsWriter::plan(
  self : LiteralsWriter,
  data : FixedArray[Byte],
  start : Int32,
  len : Int32,
) -> LiteralsPlan {
  let counts = self.counts
  let four = len >= FOUR_STREAMS_FROM
  if four {
    count_quarters(data, start, len, counts, self.quarters)
  } else {
    counts.fill(0)
    for i in start..<(start + len) {
      counts[data[i].to_int()] += 1
    }
  }
  let mut distinct = 0
  for c in counts {
    if c > 0 {
      distinct += 1
    }
  }
  let header = raw_literals_header_len(len)
  let mut best = { kind: LitRaw, size: header + len, payload: len, }
  if distinct == 1 && header + 1 < best.size {
    best = { kind: LitRle, size: header + 1, payload: 1, }
  }
  if self.huffman.build(counts) {
    let streams = if four {
      self.four_streams_size(self.huffman)
    } else {
      stream_size(self.huffman.cost(counts))
    }
    let payload = self.huffman.description_size() + streams
    let size = compressed_literals_header_len(len, payload, four) + payload
    if size < best.size {
      best = { kind: LitHuffman(four~), size, payload, }
    }
  }
  if self.previous_valid && self.previous.accepts(counts) && len > 0 {
    let payload = if four {
      self.four_streams_size(self.previous)
    } else {
      stream_size(self.previous.cost(counts))
    }
    let size = compressed_literals_header_len(len, payload, four) + payload
    if size < best.size {
      best = { kind: LitTreeless(four~), size, payload, }
    }
  }
  best
}

///|
/// The bytes of a Huffman stream of `bits` bits: they, the end mark, and
/// zero bits to a byte boundary.
fn stream_size(bits : Int32) -> Int32 {
  bits / 8 + 1
}

///|
/// The bytes of four Huffman streams and their jump table with `coder`,
/// from the counts of each stream that `plan` took.
fn LiteralsWriter::four_streams_size(
  self : LiteralsWriter,
  coder : @huffenc.HuffmanEncoder,
) -> Int32 {
  6 +
  stream_size(coder.cost(self.quarters[0])) +
  stream_size(coder.cost(self.quarters[1])) +
  stream_size(coder.cost(self.quarters[2])) +
  stream_size(coder.cost(self.quarters[3]))
}

///|
/// Writes four Huffman streams with `coder`, their jump table from the
/// counts of each stream that `plan` took.
fn LiteralsWriter::write_four_streams(
  self : LiteralsWriter,
  coder : @huffenc.HuffmanEncoder,
  out : @bits.BitPacker,
  data : FixedArray[Byte],
  start : Int32,
  len : Int32,
) -> Unit {
  coder.write_four_streams_sized(
    out,
    data,
    start,
    len,
    stream_size(coder.cost(self.quarters[0])),
    stream_size(coder.cost(self.quarters[1])),
    stream_size(coder.cost(self.quarters[2])),
  )
}

///|
/// Writes the literals section `plan` describes for
/// `data[start:start + len]`; for a Huffman plan, `plan` must be the
/// writer's latest, whose stream counts it uses.
fn LiteralsWriter::write(
  self : LiteralsWriter,
  out : @bits.BitPacker,
  plan : LiteralsPlan,
  data : FixedArray[Byte],
  start : Int32,
  len : Int32,
) -> Unit {
  match plan.kind {
    LitRaw => {
      write_raw_literals_header(out, 0, len)
      out.write_bytes(data, start, len)
    }
    LitRle => {
      write_raw_literals_header(out, 1, len)
      out.write(8, data[start].to_int())
    }
    LitHuffman(four~) => {
      write_compressed_literals_header(out, len, plan.payload, four)
      self.huffman.write_description(out)
      if four {
        self.write_four_streams(self.huffman, out, data, start, len)
      } else {
        self.huffman.write_literals(out, data, start, len, four_streams=false)
      }
      let old = self.previous
      self.previous = self.huffman
      self.huffman = old
      self.previous_valid = true
    }
    LitTreeless(four~) => {
      // The header differs only in Literals_Block_Type.
      out.write(2, 3)
      write_compressed_literals_sizes(out, len, plan.payload, four)
      if four {
        self.write_four_streams(self.previous, out, data, start, len)
      } else {
        self.previous.write_literals(out, data, start, len, four_streams=false)
      }
    }
  }
}

///|
/// The length of a raw or RLE literals header for `regenerated` literals:
/// Size_Format holds 5, 12 or 20 bits of it (section 3.1.1.3.1.1).
fn raw_literals_header_len(regenerated : Int32) -> Int32 {
  if regenerated < 32 {
    1
  } else if regenerated < 4096 {
    2
  } else {
    3
  }
}

///|
/// Writes a raw (`literals_type` 0) or RLE (1) literals header for
/// `regenerated` literals, at most 2^20 - 1.
fn write_raw_literals_header(
  out : @bits.BitPacker,
  literals_type : Int32,
  regenerated : Int32,
) -> Unit {
  out.write(2, literals_type)
  match raw_literals_header_len(regenerated) {
    1 => {
      out.write(1, 0)
      out.write(5, regenerated)
    }
    2 => {
      out.write(2, 1)
      out.write(12, regenerated)
    }
    _ => {
      out.write(2, 3)
      out.write(20, regenerated)
    }
  }
}

///|
/// The length of a compressed literals header for `regenerated` literals
/// that take `compressed` bytes: one stream has only Size_Format 0, both
/// sizes in 10 bits; four streams have 10, 14 or 18 bits each, enough for
/// the larger. A single stream is used only below 256 literals, which never
/// take 1024 bytes.
fn compressed_literals_header_len(
  regenerated : Int32,
  compressed : Int32,
  four : Bool,
) -> Int32 {
  let largest = regenerated.max(compressed)
  if !four || largest < 1024 {
    3
  } else if largest < 16384 {
    4
  } else {
    5
  }
}

///|
/// Writes a compressed literals header (Literals_Block_Type 2) for
/// `regenerated` literals in `compressed` bytes, one stream or four.
fn write_compressed_literals_header(
  out : @bits.BitPacker,
  regenerated : Int32,
  compressed : Int32,
  four : Bool,
) -> Unit {
  out.write(2, 2)
  write_compressed_literals_sizes(out, regenerated, compressed, four)
}

///|
fn write_compressed_literals_sizes(
  out : @bits.BitPacker,
  regenerated : Int32,
  compressed : Int32,
  four : Bool,
) -> Unit {
  let (size_format, width) = match
    compressed_literals_header_len(regenerated, compressed, four) {
    3 => (if four { 1 } else { 0 }, 10)
    4 => (2, 14)
    _ => (3, 18)
  }
  out.write(2, size_format)
  out.write(width, regenerated)
  out.write(width, compressed)
}

///|
/// Block_Type values (section 3.1.1.2.2).
const RAW_BLOCK : Int32 = 0

///|
const RLE_BLOCK : Int32 = 1

///|
const COMPRESSED_BLOCK : Int32 = 2

///|
/// Writes a block header: Last_Block, Block_Type and Block_Size in 3 bytes.
fn write_block_header(
  out : @bits.BitPacker,
  last : Bool,
  block_type : Int32,
  size : Int32,
) -> Unit {
  out.write(1, if last { 1 } else { 0 })
  out.write(2, block_type)
  out.write(21, size)
}

///|
/// Writes the unfinished history range as one block, the smallest of three: raw; RLE when
/// every byte is the same (and there are at least two); compressed, with
/// gathered literals and sequences, when it is smaller than raw.
/// A compressed block is thus never larger than the block limit. An empty
/// block is raw.
fn Encoder::write_matched_block(self : Encoder, n : Int32, last : Bool) -> Unit {
  let out = self.writer
  let literals = self.literals
  let data = self.matcher.history().buffer()
  let start = self.matcher.history().block_start()
  guard n > 0 else {
    write_block_header(out, last, RAW_BLOCK, 0)
    return
  }
  if n > 1 && all_same(data, start, n) {
    // RLE is strictly smaller than raw for more than one byte.
    write_block_header(out, last, RLE_BLOCK, n)
    out.write(8, data[start].to_int())
  } else {
    let block = self.sequences
    // The section's size decides the block header and the block's type, so
    // it is written aside first: its FSE states, and with them its size,
    // are known only by encoding every sequence.
    self.sequence_bits.reset()
    self.sequence_writer.write(self.sequence_bits, block)
    let size = self.sequence_bits.pending()
    let plan = literals.plan(block.literals, 0, block.literal_count)
    if plan.size + size < n {
      write_block_header(out, last, COMPRESSED_BLOCK, plan.size + size)
      literals.write(out, plan, block.literals, 0, block.literal_count)
      out.write_pending(self.sequence_bits)
      self.sequence_writer.commit(block)
    } else {
      write_block_header(out, last, RAW_BLOCK, n)
      out.write_bytes(data, start, n)
    }
  }
}

///|
/// Whether the `n` bytes of `data` from `start` all equal the first.
/// Native and Wasm compare eight at a time, unchecked.
#cfg(any(target="native", target="wasm"))
fn all_same(data : FixedArray[Byte], start : Int32, n : Int32) -> Bool {
  let bytes = data.unsafe_reinterpret_as_bytes()
  let first = data[start]
  let word = first.to_uint64() * 0x0101010101010101UL
  let end = start + n
  let mut i = start
  // data[start:end] is the caller's valid range: each load ends by `end`.
  while i + 8 <= end {
    if bytes.unsafe_read_uint64_le(i) != word {
      return false
    }
    i += 8
  }
  while i < end {
    // start <= i < end.
    if data.unsafe_get(i) != first {
      return false
    }
    i += 1
  }
  true
}

///|
#cfg(not(any(target="native", target="wasm")))
fn all_same(data : FixedArray[Byte], start : Int32, n : Int32) -> Bool {
  for i in 1..<n {
    if data[start + i] != data[start] {
      return false
    }
  }
  true
}

///|
/// Writes the magic number and the frame header (section 3.1.1.1): the
/// content size when known, in the shortest field that holds it as zstd
/// writes it, and the window as a Window_Descriptor with no mantissa unless
/// the frame is single-segment. No dictionary.
fn write_frame_header(
  out : @bits.BitPacker,
  content_size : Int64?,
  window_log : Int32,
  single_segment : Bool,
  checksum : Bool,
) -> Unit {
  out.write(32, FRAME_MAGIC.reinterpret_as_int())
  let fcs_flag = match content_size {
    None => 0
    Some(size) =>
      (if size >= 256 { 1 } else { 0 }) +
      (if size >= 65536 + 256 { 1 } else { 0 }) +
      (if size >= 0xFFFFFFFFL { 1 } else { 0 })
  }
  // Dictionary_ID_Flag 0, Content_Checksum_Flag, Single_Segment_Flag and
  // Frame_Content_Size_Flag.
  out.write(2, 0)
  out.write(1, if checksum { 1 } else { 0 })
  out.write(2, 0)
  out.write(1, if single_segment { 1 } else { 0 })
  out.write(2, fcs_flag)
  if !single_segment {
    out.write(8, (window_log - 10) << 3)
  }
  // A frame that is not single-segment has a content size larger than its
  // window, at least 1 KiB, so its flag is never 0 with a size: the field
  // of flag 0 exists only in single-segment frames.
  guard content_size is Some(size) else { return }
  match fcs_flag {
    0 => out.write(8, size.to_int())
    1 => out.write(16, (size - 256).to_int())
    2 => out.write(32, size.to_int())
    _ => {
      out.write(32, size.to_int())
      out.write(32, (size >> 32).to_int())
    }
  }
}
