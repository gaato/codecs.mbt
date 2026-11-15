// Dictionaries (RFC 8878 section 5): bytes that come, for every frame, as if
// just before its output, so that its first matches can reach into them.
// The frame names a dictionary by its Dictionary_ID; one of raw content has
// none, and is used for frames that name none.

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
}

///|
/// A dictionary of raw content, `content` itself: its id is 0, so it is
/// used for frames that name no dictionary, as RFC 8878 section 5 and zstd
/// use one, and RFC 9842's `dcz` coding does.
pub fn Dictionary::raw(content : BytesView) -> Dictionary {
  { content, id: 0, }
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
