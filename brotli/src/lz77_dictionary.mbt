// The LZ77 dictionary of Shared Brotli (RFC 9841 section 3.2), as RFC
// 9842's `dcb` coding uses one: bytes outside the window that backward
// distances past the window's reach address, before the static dictionary.

///|
/// A dictionary of raw bytes for `Decoder` and `Encoder`, held by reference
/// (the bytes it is a view of stay alive as long as it does).
pub struct Dictionary {
  priv content : BytesView
  // What encoders search it with, built by the first that needs it.
  priv mut index : DictionaryIndex?
}

///|
/// A dictionary of `content`, as RFC 9841 section 3.2 calls an LZ77
/// dictionary and `brotli -D` takes one.
pub fn Dictionary::Dictionary(content : BytesView) -> Dictionary {
  { content, index: None, }
}

///|
/// Bytes the dictionary holds of its own: once an encoder has used it, the
/// index encoders search it with, a copy of its content and five bytes per
/// byte of it at most, shared by every encoder given it. Its content is
/// the caller's and not counted.
pub fn Dictionary::memory_usage(self : Dictionary) -> Int32 {
  match self.index {
    Some(index) =>
      index.bytes.length() + 4 * (index.head.length() + index.chain.length())
    None => 0
  }
}

///|
/// The dictionary's bytes.
pub fn Dictionary::content(self : Dictionary) -> BytesView {
  self.content
}

///|
/// The dictionary's length in bytes.
pub fn Dictionary::length(self : Dictionary) -> Int32 {
  self.content.length()
}

///|
/// The bytes of a copy from the dictionary, as far as the output allows.
fn Decoder::dictionary_copy(self : Decoder) -> Status? {
  guard self.dictionary is Some(dict) else {
    abort("dictionary_copy without a dictionary")
  }
  let content = dict.content
  while self.copy_remaining > 0 {
    let want = self.copy_remaining.min(1 << 16)
    if self.free_space() < want {
      self.drain()
    }
    let n = want.min(self.free_space())
    if n == 0 {
      return Some(NeedMoreOutput)
    }
    self.ensure_space(n) |> ignore
    for i in 0..<n {
      self.put(content[self.dict_at + i])
    }
    self.dict_at += n
    self.copy_remaining -= n
  }
  self.state = if self.meta_remaining == 0 { MetaDone } else { CommandStart }
  None
}

///|
/// How an encoder finds matches in an LZ77 dictionary: every position's
/// four-byte hash chained to the one before with the same hash. Built once,
/// read only after, so encoders share it.
priv struct DictionaryIndex {
  bytes : FixedArray[Byte]
  // For each hash, the latest position with it, plus one (0 for none); for
  // each position, the one before with its hash, plus one.
  head : FixedArray[Int32]
  chain : FixedArray[Int32]
  bits : Int32
}

///|
/// The candidates a search of the dictionary looks at.
const DICTIONARY_ATTEMPTS : Int32 = 16

///|
/// The longest distance with NPOSTFIX and NDIRECT 0 (RFC 7932 section 4):
/// a match into the dictionary further back is not taken.
const MAX_CODED_DISTANCE : Int32 = 67108860

///|
fn DictionaryIndex::new(content : BytesView) -> DictionaryIndex {
  let n = content.length()
  let bytes = content.to_fixedarray()
  // A table about as long as the dictionary, of 256 to 2^17 entries.
  let bits = (if n < 2 { 1 } else { 32 - (n - 1).clz() }).clamp(min=8, max=17)
  let head = FixedArray::make(1 << bits, 0)
  let chain = FixedArray::make(n, 0)
  // p + 4 <= n: hash4 reads four bytes of the dictionary.
  for p in 0..<(n - 3) {
    let h = @lz77.hash4(bytes, p, bits)
    chain[p] = head[h]
    head[h] = p + 1
  }
  { bytes, head, chain, bits, }
}

///|
/// The dictionary's index, built the first time.
fn Dictionary::search_index(self : Dictionary) -> DictionaryIndex {
  match self.index {
    Some(index) => index
    None => {
      let index = DictionaryIndex::new(self.content)
      self.index = Some(index)
      index
    }
  }
}

///|
/// The longest match for `data[pos..pos + limit)` in the dictionary longer
/// than `best`, with the distance a decoder reads it from at `reach`, the
/// window's reach (RFC 9841 section 3.2: `reach` plus the bytes from the
/// match to the dictionary's end); `best` if none. A match never runs past
/// the dictionary's end, which the reference decoder refuses. `pos + 4`
/// is within `data` when `limit` is at least 4.
fn Encoder::dictionary_match(
  self : Encoder,
  index : DictionaryIndex,
  pos : Int32,
  limit : Int32,
  reach : Int32,
  best : Int32,
) -> Int32 {
  guard limit >= @lz77.MIN_MATCH else { return best }
  let bytes = index.bytes
  let n = bytes.length()
  let data = self.data
  let mut best = best
  let mut q = index.head[@lz77.hash4(data, pos, index.bits)] - 1
  let mut attempts = DICTIONARY_ATTEMPTS
  while q >= 0 && attempts > 0 {
    let dist = reach + (n - q)
    if dist > MAX_CODED_DISTANCE {
      // Older candidates lie further back still.
      break
    }
    let most = limit.min(n - q)
    if most > best {
      let mut len = 0
      while len < most && bytes[q + len] == data[pos + len] {
        len += 1
      }
      if len > best && len >= @lz77.MIN_MATCH {
        best = len
        self.found_dist = dist
      }
    }
    q = index.chain[q] - 1
    attempts -= 1
  }
  best
}
