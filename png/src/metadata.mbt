// The chunks a decoder was asked to report: gathered whole, within
// `max_chunk_bytes`, until their CRC has passed, then handed out as one
// block of `Metadata`. iCCP's profile, zTXt's text and iTXt's compressed text
// are inflated as they come by a zlib decoder of their own, made only when
// one of them is asked for: APNG allows text chunks between the fdAT chunks
// of one frame, in the middle of the image data's zlib stream.

///|
/// Where a block's data is in its chunk.
priv enum Mode {
  /// Copied as it is.
  Raw
  /// The keyword and the fields before a compressed field (or iTXt's
  /// text), checked byte by byte.
  Prefix
  /// The compressed field, through the zlib decoder.
  Inflate
  /// After the zlib stream: what follows is dropped.
  Finished
  /// The chunk is not what its type says; it will be left out.
  Bad
}

///|
/// The block of a reported chunk.
priv struct Block {
  max : Int32
  inflater : @zlib.Decoder?
  mut data : FixedArray[Byte]
  mut len : Int32
  mut mode : Mode
  mut index : Int32
  mut chunk : UInt32
  // In the prefix: where the keyword's NUL is, how many fields have ended
  // since, and iTXt's compression flag.
  mut keyword_end : Int32
  mut fields_seen : Int32
  mut compressed : Bool
}

///|
/// A block for chunks of at most `max` bytes, inflated ones too, with a
/// zlib decoder when `inflate`.
fn Block::new(max : Int32, inflate : Bool) -> Block {
  {
    max,
    inflater: if inflate {
      Some(@zlib.Decoder::Decoder(until=EndOfMember))
    } else {
      None
    },
    data: FixedArray::make(0, b'\x00'),
    len: 0,
    mode: Raw,
    index: -1,
    chunk: 0,
    keyword_end: -1,
    fields_seen: 0,
    compressed: false,
  }
}

///|
/// Begins the block of a chunk of type `chunk`, `index` in `@rules.known`
/// (-1 for an unknown type), `length` bytes long.
fn Block::start(
  self : Block,
  chunk : UInt32,
  index : Int32,
  length : Int32,
) -> Unit {
  self.chunk = chunk
  self.index = index
  self.len = 0
  self.keyword_end = -1
  self.fields_seen = 0
  self.compressed = false
  let packed = index is (@rules.ICCP | @rules.ZTXT | @rules.ITXT)
  self.mode = if packed { Prefix } else { Raw }
  if packed && self.inflater is Some(inflater) {
    inflater.reset()
  }
  // A chunk copied as it is takes its length; one that inflates grows.
  self.data = FixedArray::make(
    if packed {
      self.max.min(256)
    } else {
      length
    },
    b'\x00',
  )
}

///|
/// Drops the block's data.
fn Block::release(self : Block) -> Unit {
  self.data = FixedArray::make(0, b'\x00')
  self.len = 0
}

///|
/// Bytes held: the block's data, and the zlib decoder when there is one.
fn Block::memory(self : Block) -> Int32 {
  self.data.length() +
  (match self.inflater {
    Some(inflater) => inflater.memory_usage()
    None => 0
  })
}

///|
/// Makes room for `n` more bytes, which the caller has checked are within
/// `max`: a chunk copied as it is was checked against it from its length,
/// and the zlib decoder is given room only below it.
fn Block::grow(self : Block, n : Int32) -> Unit {
  guard self.len + n > self.data.length() else { return }
  let bigger = FixedArray::make(
    (self.len + n).max(self.data.length() * 2).max(256).min(self.max),
    b'\x00',
  )
  self.data.blit_to(bigger, len=self.len)
  self.data = bigger
}

///|
/// Adds `data`, the chunk's next bytes, to the block.
fn Block::feed(self : Block, data : BytesView) -> Unit raise Stop {
  let mut rest = data
  while rest.length() > 0 {
    match self.mode {
      Raw => {
        // The data was sized for the chunk's length, and an iTXt's
        // uncompressed text fits in what its prefix leaves.
        self.grow(rest.length())
        self.data.blit_from_bytesview(self.len, rest)
        self.len += rest.length()
        return
      }
      Prefix => {
        self.grow(1)
        self.data[self.len] = rest[0]
        self.len += 1
        rest = rest[1:]
        self.prefix_byte()
      }
      // The zlib decoder takes all its input or makes progress, given room;
      // without room, `inflate` raises.
      Inflate => rest = rest[self.inflate(rest):]
      Finished | Bad => return
    }
  }
}

///|
/// Checks the prefix byte just added, at `len - 1`: a keyword of 1 to 79
/// bytes and its NUL; for iCCP and zTXt, a compression method of 0, which
/// the block leaves out; for iTXt, a compression flag of 0 or 1 and a method
/// of 0, both written as 0 in the block, and the language tag's and the
/// translated keyword's NULs.
fn Block::prefix_byte(self : Block) -> Unit {
  let at = self.len - 1
  let byte = self.data[at]
  if self.keyword_end < 0 {
    if byte == b'\x00' {
      self.mode = if at == 0 { Bad } else { Prefix }
      self.keyword_end = at
    } else if at >= 79 {
      self.mode = Bad
    }
    return
  }
  let after = at - self.keyword_end
  if self.index != @rules.ITXT {
    // The compression method, dropped from the block.
    self.len -= 1
    self.mode = if byte == b'\x00' { Inflate } else { Bad }
    return
  }
  if after == 1 {
    guard byte <= b'\x01' else {
      self.mode = Bad
      return
    }
    self.compressed = byte == b'\x01'
    self.data[at] = b'\x00'
  } else if after == 2 {
    if byte != b'\x00' {
      self.mode = Bad
    }
  } else if byte == b'\x00' {
    // The language tag's NUL, then the translated keyword's.
    self.fields_seen += 1
    if self.fields_seen == 2 {
      self.mode = if self.compressed { Inflate } else { Raw }
    }
  }
}

///|
/// One step of the zlib decoder over `input` into the block; returns the
/// bytes it took. A full block (`max` bytes) is given an empty slice, so that
/// a stream that ends there is still whole, and one that would write more is
/// refused.
fn Block::inflate(self : Block, input : BytesView) -> Int32 raise Stop {
  // A block of a type that inflates exists only with the zlib decoder.
  let inflater = self.inflater.unwrap()
  if self.len < self.max {
    self.grow(1)
  }
  let status = inflater.step(
    input,
    self.data.mut_view(start=self.len),
    end=false,
  ) catch {
    _ => {
      self.mode = Bad
      return input.length()
    }
  }
  self.len += inflater.last_produced()
  match status {
    Done => self.mode = Finished
    NeedMoreOutput if self.len == self.max => self.over()
    _ => ()
  }
  inflater.last_consumed()
}

///|
/// Refuses a chunk that inflates to more than `max` bytes.
fn Block::over(self : Block) -> Unit raise Stop {
  raise Fail(
    LimitExceeded({
      resource: Memory,
      needed: None,
      limit: self.max.to_uint64(),
    }),
    "\{@rules.type_name(self.chunk)} inflates to more than max_chunk_bytes",
  )
}

///|
/// Ends the block once the chunk's data is all in, drawing what the zlib
/// decoder still holds, and says whether the chunk is what its type says.
fn Block::finish(self : Block) -> Bool raise Stop {
  while self.mode is Inflate {
    let before = self.len
    let _ = self.inflate(b"")
    if self.mode is Inflate && self.len == before {
      // The zlib stream does not end in the chunk.
      return false
    }
  }
  self.mode is (Raw | Finished)
}
