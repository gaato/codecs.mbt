// Dictionaries (RFC 8878 section 5): bytes that come, for every frame, as if
// just before its output, so that its first matches can reach into them.
// The frame names a dictionary by its Dictionary_ID; one of raw content has
// none, and is used for frames that name none. A formatted dictionary, as
// `zstd --train` writes them, also holds entropy tables and repeat offsets
// that a frame starts from.

///|
/// The magic number of a formatted dictionary.
const DICT_MAGIC : UInt32 = 0xEC30A437

///|
/// What a formatted dictionary gives a frame to start from: the literals'
/// Huffman table, the three sequence tables, and the repeat offsets.
priv struct Entropy {
  huffman : Huffman
  of : Fse
  ml : Fse
  ll : Fse
  rep : FixedArray[UInt32]
  // What an encoder starts from: the literals' weights, and each sequence
  // table's normalized counts and accuracy log.
  weights : FixedArray[Int32]
  of_norm : FixedArray[Int32]
  ml_norm : FixedArray[Int32]
  ll_norm : FixedArray[Int32]
}

///|
/// The longest dictionary content the encoder puts before a frame: of a
/// longer one, its last this many bytes. The encoder's history holds twice
/// the window and the dictionary in 32-bit indices, and 512 MiB keeps that
/// within range at every level; a decoder given the whole dictionary still
/// reads the frames, which never reach before what the encoder kept.
const MAX_ENCODER_DICTIONARY : Int32 = 1 << 29

///|
/// The part of `content` the encoder uses: all of it, or its last
/// `MAX_ENCODER_DICTIONARY` bytes.
fn encoder_view(content : BytesView) -> BytesView {
  content[(content.length() - MAX_ENCODER_DICTIONARY).max(0):]
}

///|
/// A dictionary for `Decoder` and `Encoder`: its content, held by reference
/// (the bytes it is a view of stay alive as long as it does), and its id.
pub struct Dictionary {
  priv content : BytesView
  priv id : UInt32
  priv entropy : Entropy?
}

///|
/// A dictionary of raw content, `content` itself: its id is 0, so it is
/// used for frames that name no dictionary, as RFC 8878 section 5 and zstd
/// use one, and RFC 9842's `dcz` coding does.
pub fn Dictionary::raw(content : BytesView) -> Dictionary {
  { content, id: 0, entropy: None, }
}

///|
/// A dictionary from `data`, as `zstd -D` reads one: a formatted
/// dictionary (RFC 8878 section 5, as `zstd --train` writes them) if it
/// starts with the magic number 0xEC30A437, raw content otherwise. The
/// content is a view of `data`.
///
/// Raises `Corrupt` for a formatted dictionary whose entropy tables do not
/// parse, whose repeat offsets are 0 or longer than its content, or that
/// ends inside them.
pub fn Dictionary::parse(
  data : BytesView,
) -> Dictionary raise @codec.CodecError {
  if data.length() < 8 ||
    (
      data[0].to_uint() |
      (data[1].to_uint() << 8) |
      (data[2].to_uint() << 16) |
      (data[3].to_uint() << 24)
    ) !=
    DICT_MAGIC {
    return Dictionary::raw(data)
  }
  let bytes = data.to_fixedarray()
  let le32 = (at : Int32) => {
    bytes[at].to_uint() |
    (bytes[at + 1].to_uint() << 8) |
    (bytes[at + 2].to_uint() << 16) |
    (bytes[at + 3].to_uint() << 24)
  }
  let id = le32(4)
  let end = bytes.length()
  let scratch = FseScratch::new()
  let huffman = Huffman::new()
  let of = Fse::new(8)
  let ml = Fse::new(9)
  let ll = Fse::new(9)
  let norm = () => FixedArray::makei(scratch.count, i => scratch.probs[i])
  let (at, of_norm, ml_norm, ll_norm) = try {
    let mut at = 8
    at += huffman.read(bytes, at, end, scratch)
    at += of.read(bytes, at, end, 8, MAX_OF_SYMBOL, scratch)
    let of_norm = norm()
    at += ml.read(bytes, at, end, 9, MAX_ML_CODE, scratch)
    let ml_norm = norm()
    at += ll.read(bytes, at, end, 9, MAX_LL_CODE, scratch)
    (at, of_norm, ml_norm, norm())
  } catch {
    Fail(_, message) =>
      raise CodecError(Corrupt, "a dictionary's entropy tables: \{message}")
    NeedInput =>
      raise CodecError(Corrupt, "a dictionary's entropy tables are cut short")
  }
  guard end - at >= 12 else {
    raise CodecError(Corrupt, "a dictionary that ends in its repeat offsets")
  }
  let content = data[at + 12:]
  let rep = FixedArray::makei(3, i => le32(at + 4 * i))
  for r in rep {
    if r == 0 || r.to_uint64() > content.length().to_uint64() {
      raise CodecError(
        Corrupt,
        "a dictionary's repeat offset \{r} outside its \{content.length()}-byte content",
      )
    }
  }
  let weights = FixedArray::makei(huffman.symbols, i => huffman.weights[i])
  {
    content,
    id,
    entropy: Some({
      huffman,
      of,
      ml,
      ll,
      rep,
      weights,
      of_norm,
      ml_norm,
      ll_norm,
    }),
  }
}

///|
/// Whether the dictionary is formatted: has entropy tables and repeat
/// offsets of its own.
pub fn Dictionary::is_formatted(self : Dictionary) -> Bool {
  self.entropy is Some(_)
}

///|
/// The id a frame names this dictionary by: 0 for raw content.
pub fn Dictionary::id(self : Dictionary) -> UInt32 {
  self.id
}

///|
/// The content: the bytes that come before every frame's output.
pub fn Dictionary::content(self : Dictionary) -> BytesView {
  self.content
}

///|
/// Copies a match of `n` bytes from `offset` back that reaches before the
/// frame's output, into the dictionary: `offset` more than the `p` bytes
/// of output so far and at most `p` plus the dictionary's length, as zstd
/// takes it (the dictionary stays reachable however long the frame is). The
/// bytes before the frame's output come from the dictionary's end; a match
/// that runs on past them reads the output from the frame's start, which
/// must still be within the window. Anything else is an offset beyond the
/// decoded data.
fn Decoder::copy_from_dictionary(
  self : Decoder,
  offset : Int32,
  n : Int32,
) -> Unit raise Stop {
  let p = self.frame_out + self.block_out.to_uint64()
  let reach = offset.to_uint64()
  guard self.dictionary is Some(dict) &&
    offset > 0 &&
    reach > p &&
    reach - p <= dict.content.length().to_uint64() else {
    raise corrupt("an offset beyond the decoded data")
  }
  let content = dict.content
  // `reach - p` is at most the dictionary's length, an Int.
  let back = (reach - p).to_int()
  let from_dict = back.min(n)
  self.reserve_window(n)
  let mut at = content.length() - back
  let mut remaining = from_dict
  while remaining > 0 {
    let chunk = remaining.min(self.ring.length() - self.wpos)
    for i in 0..<chunk {
      self.ring[self.wpos + i] = content[at + i]
    }
    self.advance(chunk)
    at += chunk
    remaining -= chunk
  }
  let rest = n - from_dict
  if rest > 0 {
    // The match reaches the frame's first byte, `offset` back.
    if offset > self.filled {
      raise corrupt("an offset beyond the decoded data")
    }
    self.copy_back(offset, rest)
  }
}
