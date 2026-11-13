// Huffman literal codes for the encoder (RFC 8878 section 4.2). The decoder
// builds its table from weights: a symbol of weight `w` takes 2^(w - 1)
// entries of a table of 2^Max_Number_of_Bits, in order of weight and then
// symbol, and is read as the top `Max_Number_of_Bits + 1 - w` bits of the
// next Max_Number_of_Bits. So the code of each symbol here is its first
// entry in that table, shifted down: the codes come from the weights by the
// decoder's own rule, rather than from a canonical order of their own.

///|
/// The longest Huffman code (RFC 8878 section 4.2.1).
pub const MAX_BITS : Int32 = 11

///|
/// The largest accuracy log of the FSE table that compresses weights.
const WEIGHT_LOG : Int32 = 6

///|
/// Builds Huffman codes for literals, writes their tree description, and
/// encodes literal streams with them. Holds the last code it built.
pub struct HuffmanEncoder {
  priv maker : @huffman_code.CodeMaker
  // Per symbol: code length (0 for none), code, weight.
  priv lengths : FixedArray[Int32]
  priv codes : FixedArray[Int32]
  priv weights : FixedArray[Int32]
  // The symbols up to the last one with a code, and the longest code.
  priv mut symbols : Int32
  priv mut max_bits : Int32
  // The tree description of the code.
  priv description : FixedArray[Byte]
  priv mut description_size : Int32
  // Scratch: the weights' counts and distribution, their FSE table, where
  // each weight's entries start, and a bit writer for weights only.
  priv weight_counts : FixedArray[Int32]
  priv weight_norm : FixedArray[Int32]
  priv weight_table : @fse.CTable
  priv entry_start : FixedArray[Int32]
  priv packer : @bits.BitPacker
}

///|
/// An encoder with no code yet.
pub fn HuffmanEncoder::HuffmanEncoder() -> HuffmanEncoder {
  {
    maker: @huffman_code.CodeMaker(max_alphabet=256),
    lengths: FixedArray::make(256, 0),
    codes: FixedArray::make(256, 0),
    weights: FixedArray::make(256, 0),
    symbols: 0,
    max_bits: 0,
    // One byte of header, then at most 127 bytes of FSE-compressed weights
    // or 64 bytes of direct ones.
    description: FixedArray::make(128, b'\x00'),
    description_size: 0,
    weight_counts: FixedArray::make(MAX_BITS + 1, 0),
    weight_norm: FixedArray::make(MAX_BITS + 1, 0),
    weight_table: @fse.CTable(max_log=WEIGHT_LOG, max_symbols=MAX_BITS + 1),
    entry_start: FixedArray::make(MAX_BITS + 2, 0),
    packer: @bits.BitPacker(),
  }
}

///|
/// The bytes the encoder holds, apart from the streams it has buffered.
pub fn HuffmanEncoder::memory_usage(self : HuffmanEncoder) -> Int32 {
  self.maker.memory_usage() +
  4 *
  (
    self.lengths.length() +
    self.codes.length() +
    self.weights.length() +
    self.weight_counts.length() +
    self.weight_norm.length() +
    self.entry_start.length()
  ) +
  self.description.length() +
  self.weight_table.memory_usage() +
  self.packer.capacity()
}

///|
/// Builds a code for literals whose byte values occur `counts[b]` times
/// (256 counts, adding up to at most 2^17) and its tree description. False
/// when there is no code to use: fewer than two byte values occur (the
/// caller writes the literals raw, or as one repeated byte), or the code
/// cannot be described, which happens only when more than 128 weights are
/// all equal (every byte value from 0 to the last one, coded in as many
/// bits, which saves nothing over raw literals).
pub fn HuffmanEncoder::build(
  self : HuffmanEncoder,
  counts : FixedArray[Int32],
) -> Bool {
  let mut last = -1
  let mut used = 0
  for s in 0..<256 {
    if counts[s] > 0 {
      last = s
      used += 1
    }
  }
  guard used >= 2 else { return false }
  let n = last + 1
  self.maker.make(counts, n, MAX_BITS, self.lengths, self.codes)
  let mut max_bits = 0
  for s in 0..<n {
    max_bits = max_bits.max(self.lengths[s])
  }
  self.symbols = n
  self.max_bits = max_bits
  for s in 0..<n {
    let len = self.lengths[s]
    self.weights[s] = if len > 0 { max_bits + 1 - len } else { 0 }
  }
  self.assign_codes()
  self.describe()
}

///|
/// Gives each symbol the code of its first entry in the decoder's table:
/// the entries go by weight, then symbol, each weight `w` taking 2^(w - 1)
/// of them per symbol.
fn HuffmanEncoder::assign_codes(self : HuffmanEncoder) -> Unit {
  let start = self.entry_start
  start.fill(0)
  for s in 0..<self.symbols {
    let w = self.weights[s]
    if w > 0 {
      start[w + 1] += 1 << (w - 1)
    }
  }
  for w in 1..<=self.max_bits {
    start[w + 1] += start[w]
  }
  for s in 0..<self.symbols {
    let w = self.weights[s]
    if w > 0 {
      self.codes[s] = start[w] >> (w - 1)
      start[w] += 1 << (w - 1)
    } else {
      self.codes[s] = 0
    }
  }
}

///|
/// Writes the tree description of the code into `self.description`: the
/// weights of every symbol but the last (whose weight the decoder works
/// out), FSE-compressed or four bits each, whichever is shorter and
/// possible. False when neither is.
fn HuffmanEncoder::describe(self : HuffmanEncoder) -> Bool {
  let count = self.symbols - 1
  let direct = if count <= 128 { 1 + (count + 1) / 2 } else { 256 }
  let compressed = self.compress_weights(count)
  // The header byte states at most 127 bytes of compressed weights.
  if compressed <= 128 && compressed < direct {
    // `compress_weights` left them in the description.
    self.description_size = compressed
    return true
  }
  guard count <= 128 else { return false }
  self.description[0] = (127 + count).to_byte()
  for i = 0; i < count; i = i + 2 {
    let high = self.weights[i]
    let low = if i + 1 < count { self.weights[i + 1] } else { 0 }
    self.description[1 + i / 2] = ((high << 4) | low).to_byte()
  }
  self.description_size = direct
  true
}

///|
/// Compresses the first `count` weights with FSE and returns the bytes they
/// take with their header byte, having written them into
/// `self.description` if they fit it; 256 when they cannot be compressed:
/// fewer than two weights, or all of them equal (a table of one symbol
/// reads no bits, and the decoder finds the end of the weights by running
/// out of bits).
fn HuffmanEncoder::compress_weights(
  self : HuffmanEncoder,
  count : Int32,
) -> Int32 {
  guard count >= 2 else { return 256 }
  let wcounts = self.weight_counts
  wcounts.fill(0)
  for i in 0..<count {
    wcounts[self.weights[i]] += 1
  }
  let mut alphabet = 0
  for w in 0..<=MAX_BITS {
    if wcounts[w] > 0 {
      if wcounts[w] == count {
        return 256
      }
      alphabet = w + 1
    }
  }
  let log = @fse.accuracy_log(count, alphabet, WEIGHT_LOG)
  let norm = self.weight_norm
  @fse.normalize(wcounts, alphabet, count, log, false, norm)
  let table = self.weight_table
  table.build(norm, alphabet, log)
  let out = self.packer
  out.reset()
  @fse.write_description(out, norm, alphabet, log)
  // Two states take turns, the first on the even weights: the decoder
  // reads both, then alternates, and stops when a transition runs past the
  // stream's start, taking the last weight from the other state. So each
  // state starts on the last weight it holds, and the one holding the next
  // to last starts on a state whose transition reads at least one bit.
  let weights = self.weights
  let mut even = 0
  let mut odd = 0
  if count % 2 == 0 {
    even = table.start(weights[count - 2])
    odd = table.start(weights[count - 1])
  } else {
    odd = table.start(weights[count - 2])
    even = table.start(weights[count - 1])
  }
  for i = count - 3; i >= 0; i = i - 1 {
    if i % 2 == 0 {
      even = table.encode(out, even, weights[i])
    } else {
      odd = table.encode(out, odd, weights[i])
    }
  }
  table.finish(out, odd)
  table.finish(out, even)
  out.write_end_mark()
  let size = out.pending()
  if size <= 127 {
    self.description[0] = size.to_byte()
    out.drain_into(self.description, 1) |> ignore
  }
  1 + size
}

///|
/// The tree description's size in bytes.
pub fn HuffmanEncoder::description_size(self : HuffmanEncoder) -> Int32 {
  self.description_size
}

///|
/// Writes the tree description into `out`, which is at a byte boundary.
pub fn HuffmanEncoder::write_description(
  self : HuffmanEncoder,
  out : @bits.BitPacker,
) -> Unit {
  out.write_bytes(self.description, 0, self.description_size)
}

///|
/// The bits the code spends on literals occurring `counts[b]` times, all of
/// them byte values the code has: the streams' size without their end marks
/// and padding.
pub fn HuffmanEncoder::cost(
  self : HuffmanEncoder,
  counts : FixedArray[Int32],
) -> Int32 {
  let mut bits = 0
  for s in 0..<self.symbols {
    bits += counts[s] * self.lengths[s]
  }
  bits
}

///|
/// The longest code length, Max_Number_of_Bits.
pub fn HuffmanEncoder::max_bits(self : HuffmanEncoder) -> Int32 {
  self.max_bits
}

///|
/// Whether every byte with a nonzero count has a code in this table.
pub fn HuffmanEncoder::accepts(
  self : HuffmanEncoder,
  counts : FixedArray[Int32],
) -> Bool {
  for s in 0..<256 {
    if counts[s] > 0 && (s >= self.symbols || self.lengths[s] == 0) {
      return false
    }
  }
  true
}

///|
/// Writes `data[start:start + len]`, literals that all have a code, into
/// `out` at a byte boundary: as one stream, or as four after their jump
/// table (at least 6 literals, RFC 8878 section 3.1.1.3.1.6), the first three
/// of `ceil(len / 4)` literals each.
pub fn HuffmanEncoder::write_literals(
  self : HuffmanEncoder,
  out : @bits.BitPacker,
  data : FixedArray[Byte],
  start : Int32,
  len : Int32,
  four_streams~ : Bool,
) -> Unit {
  if !four_streams {
    self.write_stream(out, data, start, start + len)
    return
  }
  let segment = (len + 3) / 4
  // Each jump-table entry can be written as soon as it is counted; keeping
  // all three in a temporary array would allocate on every literals block.
  for i in 0..<3 {
    let from = start + i * segment
    let mut bits = 0
    for j in from..<(from + segment) {
      bits += self.lengths[data[j].to_int()]
    }
    out.write(16, bits / 8 + 1)
  }
  for i in 0..<4 {
    let from = start + i * segment
    let until = if i < 3 { from + segment } else { start + len }
    self.write_stream(out, data, from, until)
  }
}

///|
/// One stream: the codes of `data[from:until]` from the last literal to the
/// first, since the decoder reads the stream backward, and the end mark.
fn HuffmanEncoder::write_stream(
  self : HuffmanEncoder,
  out : @bits.BitPacker,
  data : FixedArray[Byte],
  from : Int32,
  until : Int32,
) -> Unit {
  let lengths = self.lengths
  let codes = self.codes
  for i = until - 1; i >= from; i = i - 1 {
    let s = data[i].to_int()
    out.write(lengths[s], codes[s])
  }
  out.write_end_mark()
}
