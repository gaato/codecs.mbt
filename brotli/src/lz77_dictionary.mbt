// The LZ77 dictionary of Shared Brotli (RFC 9841 section 3.2), as RFC
// 9842's `dcb` coding uses one: bytes outside the window that backward
// distances past the window's reach address, before the static dictionary.

///|
/// A dictionary of raw bytes for `Decoder` and `Encoder`, held by reference
/// (the bytes it is a view of stay alive as long as it does).
pub struct Dictionary {
  priv content : BytesView
}

///|
/// A dictionary of `content`, as RFC 9841 section 3.2 calls an LZ77
/// dictionary and `brotli -D` takes one.
pub fn Dictionary::Dictionary(content : BytesView) -> Dictionary {
  { content, }
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
