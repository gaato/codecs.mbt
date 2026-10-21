// Huffman literal codes (RFC 8878 section 4.2): the tree description and
// decoding streams.

///|
/// The longest Huffman code.
const MAX_HUF_BITS : Int32 = 11

///|
/// A Huffman decoding table indexed by the next `max_bits` bits: each entry
/// gives the symbol and its code length.
priv struct Huffman {
  symbol : FixedArray[Byte]
  nbits : FixedArray[Byte]
  mut max_bits : Int32
  // Scratch: the weights of a description, how many of each weight there
  // are, and where the entries of each weight go.
  weights : FixedArray[Int32]
  weight_count : FixedArray[Int32]
  entry_start : FixedArray[Int32]
  weight_table : Fse
}

///|
fn Huffman::new() -> Huffman {
  {
    symbol: FixedArray::make(1 << MAX_HUF_BITS, b'\x00'),
    nbits: FixedArray::make(1 << MAX_HUF_BITS, b'\x00'),
    max_bits: 0,
    weights: FixedArray::make(256, 0),
    weight_count: FixedArray::make(MAX_HUF_BITS + 1, 0),
    entry_start: FixedArray::make(MAX_HUF_BITS + 2, 0),
    weight_table: Fse::new(6),
  }
}

///|
/// Reads a Huffman tree description from `data[start:end]` and builds the
/// table. Returns the bytes the description used.
fn Huffman::read(
  self : Huffman,
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
  scratch : FseScratch,
) -> Int32 raise Stop {
  if start >= end {
    raise corrupt("a Huffman tree description runs past its section")
  }
  let header = data[start].to_int()
  let weights = self.weights
  let (count, used) = if header >= 128 {
    // Direct representation: 4-bit weights, two to a byte.
    let count = header - 127
    let bytes = (count + 1) / 2
    if start + 1 + bytes > end {
      raise corrupt("a Huffman tree description runs past its section")
    }
    for i in 0..<count {
      let b = data[start + 1 + i / 2].to_int()
      weights[i] = if i % 2 == 0 { b >> 4 } else { b & 15 }
    }
    (count, 1 + bytes)
  } else {
    // FSE-compressed weights: two interleaved states.
    let size = header
    if size == 0 || start + 1 + size > end {
      raise corrupt("a Huffman tree description runs past its section")
    }
    let stream_end = start + 1 + size
    let table = self.weight_table
    let table_size = table.read(data, start + 1, stream_end, 6, 255, scratch)
    let bits = BackwardBits::new(data, start + 1 + table_size, stream_end)
    let mut state1 = bits.read(table.log)
    let mut state2 = bits.read(table.log)
    if bits.pos < 0 {
      raise corrupt("Huffman weights without their initial states")
    }
    let mut count = 0
    for ;; {
      if count > 252 {
        raise corrupt("more than 255 Huffman weights")
      }
      weights[count] = table.symbol_of(state1)
      state1 = table.next(state1, bits)
      count += 1
      if bits.pos < 0 {
        weights[count] = table.symbol_of(state2)
        count += 1
        break
      }
      weights[count] = table.symbol_of(state2)
      state2 = table.next(state2, bits)
      count += 1
      if bits.pos < 0 {
        weights[count] = table.symbol_of(state1)
        count += 1
        break
      }
    }
    (count, 1 + size)
  }
  self.build(count)
  used
}

///|
/// Builds the table from `weights[0:count]`; the last symbol's weight is
/// implied (RFC 8878 section 4.2.1.1). `@huffman.build_table` builds it, or
/// says why the weights are refused.
fn Huffman::build(self : Huffman, count : Int32) -> Unit raise Stop {
  let result = @huffman.build_table(
    self.weights,
    count,
    self.symbol,
    self.nbits,
    self.weight_count,
    self.entry_start,
  )
  // The implied last weight follows the others, once known (RFC 8878
  // section 4.2.1.1).
  if result > 0 || result == @huffman.NO_WEIGHT_ONE {
    self.weights[count] = self.entry_start[0]
  }
  if result < 0 {
    raise corrupt(
      match result {
        @huffman.WEIGHT_TOO_LARGE => "a Huffman weight above \{MAX_HUF_BITS}"
        @huffman.ONE_SYMBOL => "a Huffman tree with one symbol"
        @huffman.TOO_DEEP => "a Huffman tree deeper than \{MAX_HUF_BITS} bits"
        @huffman.INCOMPLETE => "Huffman weights that do not complete a tree"
        @huffman.NO_WEIGHT_ONE => "a Huffman tree with no weight of 1"
        _ => "Huffman weights that overfill the tree"
      },
    )
  }
  self.max_bits = result
}

///|
/// Decodes one stream, `data[start:end]`, into exactly `count` literals at
/// `out[at:]`; the stream must be used up exactly.
fn Huffman::decode_stream(
  self : Huffman,
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
  out : FixedArray[Byte],
  at : Int32,
  count : Int32,
) -> Unit raise Stop {
  let bits = BackwardBits::new(data, start, end)
  let max_bits = self.max_bits
  let symbol = self.symbol
  let nbits = self.nbits
  for i in at..<(at + count) {
    let index = bits.peek(max_bits)
    out[i] = symbol[index]
    bits.skip(nbits[index].to_int())
  }
  if bits.pos != 0 {
    raise corrupt("a Huffman stream that does not end with its literals")
  }
}

///|
/// Decodes `count` literals from `data[start:end]` into `out[0:count]`, in
/// one stream or four after a jump table.
fn Huffman::decode(
  self : Huffman,
  data : FixedArray[Byte],
  start : Int32,
  end : Int32,
  out : FixedArray[Byte],
  count : Int32,
  four_streams : Bool,
) -> Unit raise Stop {
  if !four_streams {
    self.decode_stream(data, start, end, out, 0, count)
    return
  }
  let (size1, size2, size3, _) = checked(
    @header.parse_jump_table(data[start:end]),
  )
  let s1 = start + 6
  let s2 = s1 + size1
  let s3 = s2 + size2
  let s4 = s3 + size3
  // The caller rejects four streams with fewer than 6 literals, and for 6 or
  // more the last segment is never negative.
  let segment = (count + 3) / 4
  let last = count - 3 * segment
  self.decode_stream(data, s1, s2, out, 0, segment)
  self.decode_stream(data, s2, s3, out, segment, segment)
  self.decode_stream(data, s3, s4, out, 2 * segment, segment)
  self.decode_stream(data, s4, end, out, 3 * segment, last)
}
