///|
/// A test vector: a compressed stream and what it decodes to.
pub(all) struct Vector {
  name : String
  compressed : String
  size : Int32
  sha256 : String
}

///|
/// The stream.
pub fn Vector::input(self : Vector) -> Bytes {
  decode64(self.compressed)
}

///|
/// A stream built bit by bit, the dictionary to decode it with, and what
/// zlib makes of it (see `outcome`).
pub(all) struct Crafted {
  name : String
  input : String
  dictionary : String?
  zlib : String
}

///|
/// A seeded corruption of a vector (see `corrupt`), and what zlib makes of
/// it; where zlib asks for more input, `padded` is what it makes of it
/// followed by 1 KiB of zeros, and empty otherwise.
pub(all) struct Corruption {
  source : String
  op : Int32
  at : Int32
  value : Int32
  zlib : String
  padded : String
}

///|
/// A stream of messages that each end in a sync flush, never finished: for
/// each message, the offset where its bytes end, and the length and SHA-256
/// of its text.
pub(all) struct Flushed {
  name : String
  compressed : String
  messages : Array[(Int32, Int32, String)]
}

///|
/// The bytes of a base64 literal of the generated files.
pub fn decode64(text : String) -> Bytes {
  @base64.decode(text, ignore_whitespace=true) catch {
    _ => abort("bad base64 in a vector")
  }
}

///|
/// The vector named `name` of `vectors`.
pub fn find(vectors : Array[Vector], name : String) -> Vector {
  vectors[vectors.search_by(v => v.name == name).unwrap()]
}

///|
/// `input` with the corruption applied: bit `value` of byte `at` flipped
/// (0), the byte replaced by `value` (1), `value` inserted before it (2),
/// the byte deleted (3), or the stream cut there (4).
pub fn corrupt(c : Corruption, input : Bytes) -> Bytes {
  let bytes = input.to_array()
  match c.op {
    0 => bytes[c.at] = bytes[c.at] ^ (1 << c.value).to_byte()
    1 => bytes[c.at] = c.value.to_byte()
    2 => bytes.insert(c.at, c.value.to_byte())
    3 => bytes.remove(c.at) |> ignore
    _ => bytes.truncate(c.at)
  }
  Bytes::from_array(bytes)
}

///|
/// The name of an error kind, without its arguments, as the generated files
/// write zlib's.
pub fn kind_name(kind : @codec.ErrorKind) -> String {
  match kind {
    LimitExceeded(_) => "LimitExceeded"
    DictionaryRequired(_) => "DictionaryRequired"
    kind => Repr(kind).to_string()
  }
}

///|
/// What `decoder` makes of the whole of `input`, given at once with
/// `end=true`, in the generated files' terms: `ok <consumed> <sha256>` or
/// `err <kind>`.
pub fn[D : @codec_bytes.Decode] outcome(
  decoder : D,
  input : BytesView,
) -> String {
  let out = FixedArray::make(1 << 16, b'\x00')
  let text = Buffer()
  let mut rest = input
  for ;; {
    let status = decoder.step(rest, out.mut_view(), end=true) catch {
      @codec.CodecError(kind, _) => return "err \{kind_name(kind)}"
    }
    rest = rest[decoder.last_consumed():]
    text.write_bytesview(Bytes::from_array(out[:decoder.last_produced()])[:])
    if status is Done {
      let consumed = input.length() - rest.length()
      return "ok \{consumed} \{sha256(text.to_bytes())}"
    }
  }
}

///|
/// Feeds `input` to `decoder` in chunks of `next_in()` bytes, into output
/// buffers of `next_out()` bytes, with `step_into` when given (a decoder's
/// `step_into`, into a `FixedArray`) and the trait's `step` otherwise,
/// calling `check` after every step. Returns the output and how much of
/// `input` was consumed.
pub fn[D : @codec_bytes.Decode] drive(
  decoder : D,
  input : BytesView,
  next_in~ : () -> Int32,
  next_out~ : () -> Int32,
  step_into? : (D, BytesView, FixedArray[Byte], Bool) -> @codec_bytes.Status raise @codec.CodecError,
  check~ : (D, Int32) -> Unit raise = (_, _) => (),
) -> (Bytes, Int32) raise {
  let out = Buffer()
  let mut pos = 0
  let mut pending = input[0:0]
  for ;; {
    if pending.length() == 0 && pos < input.length() {
      let next = (pos + next_in()).min(input.length())
      pending = input[pos:next]
      pos = next
    }
    let end = pos == input.length()
    let room = next_out()
    let buffer = FixedArray::make(room, b'\x00')
    let status = match step_into {
      Some(f) => f(decoder, pending, buffer, end)
      None => decoder.step(pending, buffer.mut_view(), end~)
    }
    check(decoder, room)
    pending = pending[decoder.last_consumed():]
    out.write_bytesview(Bytes::from_array(buffer[:decoder.last_produced()])[:])
    match status {
      Done => return (out.to_bytes(), pos - pending.length())
      NeedMoreInput =>
        if pending.length() != 0 {
          fail("input left on NeedMoreInput")
        }
      NeedMoreOutput =>
        if decoder.last_consumed() == 0 && decoder.last_produced() == 0 {
          fail("no progress")
        }
    }
  }
}

///|
/// A seeded pseudo-random generator (a 32-bit LCG), for reproducible tests.
pub struct Rng {
  mut state : UInt32
}

///|
pub fn Rng::new(seed : UInt32) -> Rng {
  { state: seed, }
}

///|
/// A number in `0..<bound`.
pub fn Rng::below(self : Rng, bound : Int32) -> Int32 {
  self.state = self.state * 1664525 + 1013904223
  (self.state >> 8).reinterpret_as_int() % bound
}

///|
/// Why a decoder's answers for a stream of `length` bytes disagree with
/// zlib's, `zlib`, or None when they agree. `first` is the decoder's answer
/// under `until=EndOfMember`, `whole` under `until=EndOfInput`, both in
/// `outcome`'s terms.
///
/// zlib stops reading after a raw DEFLATE or zlib stream and ignores what
/// follows; this repository's decoders leave it unread under `EndOfMember`
/// and raise `TrailingData` under `EndOfInput`. For gzip (`members=true`),
/// zlib reads every member and stops at a zero byte after one, ignoring the
/// rest, and reads anything else after a member as another, which fails; the
/// decoders here raise `TrailingData` for both, after a first member that
/// decodes.
///
/// The inflater refuses some streams before zlib does (see the crafted
/// streams' exceptions): where zlib asks for more input, a refusal as
/// `Corrupt` agrees when zlib, given zeros after the stream, refuses it as
/// `Corrupt` too (`padded`).
pub fn disagreement(
  zlib : String,
  length : Int32,
  first~ : String,
  whole~ : String,
  members~ : Bool = false,
  padded~ : String = "",
) -> String? {
  if zlib == "err Truncated" &&
    padded == "err Corrupt" &&
    first == "err Corrupt" &&
    whole == "err Corrupt" {
    return None
  }
  let stopped_early = match zlib.split(" ").collect() {
    ["ok", consumed, _] => {
      let consumed = @string.parse_int(consumed) catch { _ => length }
      consumed < length
    }
    _ => false
  }
  let expected_whole = if stopped_early { "err TrailingData" } else { zlib }
  if !members {
    if first != zlib {
      return Some("until=EndOfMember: \{first}, zlib: \{zlib}")
    }
  }
  if whole == expected_whole {
    return None
  }
  if members &&
    zlib == "err Corrupt" &&
    whole == "err TrailingData" &&
    first.has_prefix("ok ") {
    return None
  }
  Some("until=EndOfInput: \{whole}, zlib: \{zlib}")
}
