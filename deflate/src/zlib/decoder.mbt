// The streaming decoder.
//
// A zlib stream (RFC 1950) is a 2-byte header, a 4-byte dictionary id when
// FDICT is set, raw DEFLATE, and the Adler-32 of the data, big-endian. The
// header and the trailer gather in `hdr` and are judged by the pure functions
// of `@header`; the DEFLATE data goes through a `@deflate.Decoder` that stops
// right after the final block (`EndOfMember`), so the trailer is what it
// leaves of the input. Its output is the caller's, written straight into the
// caller's slice, and the Adler-32 is updated from it.
//
// The inner decoder is made when the header says whether the stream names a
// preset dictionary (FDICT), before any DEFLATE byte: with the dictionary for
// a stream that names it, without for one that does not, which ignores it as
// zlib does. A later stream (after `reset`) that needs the same kind resets
// it; one that needs the other kind replaces it. The decoder keeps the
// dictionary's last 32 KiB to make an inner decoder with it.

///|
priv enum State {
  Header
  DictionaryId
  /// The DEFLATE data, through the inner decoder.
  Data(@deflate.Decoder)
  Trailer
  /// The trailer is checked; under `EndOfInput`, `Done` waits for `end`.
  Ended
  Done
}

///|
/// The header with a dictionary id, the longest unit gathered in `hdr`.
const HEADER_MAX : Int32 = 6

///|
/// A streaming zlib decoder (RFC 1950). Feed it input in chunks of any size
/// with `step` and collect output in slices of any size; it holds a raw
/// DEFLATE decoder (a 32 KiB window and its tables) and a few header bytes,
/// never the whole input or output.
pub struct Decoder {
  // The preset dictionary's last 32 KiB and its Adler-32.
  priv dictionary : Bytes?
  priv dictionary_id : UInt32?
  // The inner decoder, once a header has been read, and whether it holds the
  // dictionary.
  priv mut inner : @deflate.Decoder?
  priv mut inner_dictionary : Bool
  priv until : @codec_bytes.Until
  // Header and trailer bytes gathered so far.
  priv hdr : FixedArray[Byte]
  priv mut hdr_len : Int32
  // The current step.
  priv mut view : BytesView
  priv mut in_pos : Int32
  priv mut out : MutArrayView[Byte]
  priv mut fixed_out : FixedArray[Byte]?
  priv mut out_pos : Int32
  priv empty_out : FixedArray[Byte]
  // Stream state.
  priv mut state : State
  priv mut adler : UInt32
  priv mut failure : @codec.CodecError?
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
}

///|
/// A decoder at the start of a stream.
///
/// `dictionary` is the preset dictionary for streams that name one (FDICT):
/// the stream's matches may reach back into its last 32 KiB. A stream that
/// names a dictionary raises `DictionaryRequired(Some(id))` without one, with
/// the Adler-32 of the dictionary it needs, and `DictionaryMismatch` when
/// `dictionary` is another; to decode it, make a new decoder with the right
/// dictionary and start over. A stream that names none ignores `dictionary`.
///
/// `until` says where the stream ends. `EndOfInput`, the default, decodes the
/// stream up to the end of the input, and bytes after its trailer raise
/// `TrailingData` (zlib streams are not concatenated). `EndOfMember` stops
/// right after the trailer and consumes nothing past it, so that
/// `input[last_consumed():]` is what follows.
pub fn Decoder::Decoder(
  dictionary? : BytesView,
  until~ : @codec_bytes.Until = EndOfInput,
) -> Decoder {
  let empty_out = FixedArray::make(0, b'\x00')
  {
    dictionary: dictionary.map(d => d[(d.length() - 32768).max(0):].to_owned()),
    dictionary_id: dictionary.map(@adler32.of_bytes),
    inner: None,
    inner_dictionary: false,
    until,
    hdr: FixedArray::make(HEADER_MAX, b'\x00'),
    hdr_len: 0,
    view: b""[:],
    in_pos: 0,
    out: empty_out.mut_view(),
    fixed_out: None,
    out_pos: 0,
    empty_out,
    state: Header,
    adler: @adler32.INITIAL,
    failure: None,
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Starts a new stream with the same options: the same dictionary, and the
/// same `until`. The inner decoder is kept, and reset when the next stream's
/// header is read.
pub fn Decoder::reset(self : Decoder) -> Unit {
  self.release_step()
  self.hdr_len = 0
  self.state = Header
  self.adler = @adler32.INITIAL
  self.failure = None
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// Bytes held for the stream: those of the raw DEFLATE decoder (see
/// `@deflate.Decoder::memory_usage`: 74,240, and the dictionary's last 32 KiB
/// when it holds one) once a header has been read, and the dictionary's last
/// 32 KiB kept to make one. At most 139,776 bytes with a dictionary, 74,240
/// without. The header and trailer bytes, at most 6, are not counted.
pub fn Decoder::memory_usage(self : Decoder) -> Int32 {
  let inner = match self.inner {
    Some(d) => d.memory_usage()
    None => 0
  }
  let dictionary = match self.dictionary {
    Some(d) => d.length()
    None => 0
  }
  inner + dictionary
}

///|
/// Whether the stream has ended: its trailer is checked and all its output
/// has been handed out. Under `EndOfInput` this can be true before `Done`,
/// which waits for `end`.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  self.state is (Ended | Done)
}

///|
/// Input bytes the latest `step` accepted: all of them on `NeedMoreInput`.
/// Zero after a step that raised.
pub fn Decoder::last_consumed(self : Decoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote. Zero after a step that raised.
pub fn Decoder::last_produced(self : Decoder) -> Int32 {
  self.step_produced
}

///|
/// Decodes from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used.
///
/// Pass `end=true` once `input` holds the last bytes and `end=false` before:
/// a stream cut short then raises `Truncated`. Under `until=EndOfInput` a
/// stream whose trailer is checked answers `NeedMoreInput` until `end`, and
/// bytes after it raise `TrailingData`; under `until=EndOfMember` it answers
/// `Done` right after the trailer, whatever `end` says. Output comes before
/// the Adler-32 that covers it is checked, so `ChecksumMismatch` can follow
/// output already handed out. After an error the decoder raises it again
/// until `reset`.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_with(input, output, None, end~)
}

///|
/// `step` into a whole `FixedArray`, with bulk copies.
pub fn Decoder::step_into(
  self : Decoder,
  input : BytesView,
  output : FixedArray[Byte],
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_with(input, output.mut_view(), Some(output), end~)
}

///|
fn Decoder::step_with(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_consumed = 0
  self.step_produced = 0
  if self.failure is Some(err) {
    raise err
  }
  self.view = input
  self.in_pos = 0
  self.out = output
  self.fixed_out = fixed_output
  self.out_pos = 0
  let status = self.run(end~) catch {
    NeedInput if end =>
      self.fail(
        CodecError(
          Truncated,
          if self.state is Header && self.hdr_len == 0 {
            "the input holds no stream"
          } else {
            "the stream ends inside its header or trailer"
          },
        ),
      )
    NeedInput => NeedMoreInput
    Fail(kind, message) => self.fail(CodecError(kind, message))
  }
  self.step_consumed = self.in_pos
  self.step_produced = self.out_pos
  self.release_step()
  status
}

///|
/// Runs the stream's units over the step's input.
fn Decoder::run(self : Decoder, end~ : Bool) -> Status raise Stop {
  for ;; {
    match self.state {
      Header => {
        self.fill(2)
        let header = checked(@header.parse(self.hdr[0], self.hdr[1]))
        if header.dictionary {
          self.state = DictionaryId
        } else {
          self.start(dictionary=false)
        }
      }
      DictionaryId => {
        self.fill(HEADER_MAX)
        let id = @header.be32(Bytes::from_array(self.hdr[2:6]))
        match self.dictionary_id {
          None =>
            raise Fail(
              DictionaryRequired(Some(id)),
              "the stream needs a preset dictionary",
            )
          Some(given) if given != id =>
            raise Fail(
              DictionaryMismatch,
              "the stream needs another preset dictionary",
            )
          Some(_) => self.start(dictionary=true)
        }
      }
      Data(inner) => {
        let rest = self.view[self.in_pos:]
        let room = self.out.mut_view(start=self.out_pos)
        let status = try {
          match self.fixed_out {
            Some(fixed) if self.out_pos == 0 =>
              inner.step_into(rest, fixed, end~)
            _ => inner.step(rest, room, end~)
          }
        } catch {
          // The DEFLATE data's error, whatever its kind.
          CodecError(kind, message) => raise Fail(kind, message)
        }
        let produced = inner.last_produced()
        self.adler = @adler32.update(self.adler, room.exact_view(end=produced))
        self.in_pos += inner.last_consumed()
        self.out_pos += produced
        match status {
          Done => {
            self.hdr_len = 0
            self.state = Trailer
          }
          NeedMoreInput => return NeedMoreInput
          NeedMoreOutput => return NeedMoreOutput
        }
      }
      Trailer => {
        self.fill(4)
        checked(
          @header.check_trailer(self.adler, Bytes::from_array(self.hdr[0:4])),
          kind=ChecksumMismatch,
        )
        self.state = if self.until is EndOfMember { Done } else { Ended }
      }
      Ended =>
        if self.in_pos < self.view.length() {
          raise Fail(TrailingData, "data after the end of the stream")
        } else if end {
          self.state = Done
        } else {
          return NeedMoreInput
        }
      Done => {
        if self.until is EndOfInput && self.in_pos < self.view.length() {
          raise Fail(TrailingData, "data after the end of the stream")
        }
        return Done
      }
    }
  }
}

///|
/// Begins the DEFLATE data, with or without the preset dictionary: resets the
/// inner decoder when it is of that kind, makes one otherwise.
fn Decoder::start(self : Decoder, dictionary~ : Bool) -> Unit {
  let inner = match self.inner {
    Some(d) if self.inner_dictionary == dictionary => {
      d.reset()
      d
    }
    _ => {
      let d = match self.dictionary {
        Some(bytes) if dictionary =>
          @deflate.Decoder(dictionary=bytes, until=EndOfMember)
        _ => @deflate.Decoder(until=EndOfMember)
      }
      self.inner = Some(d)
      self.inner_dictionary = dictionary
      d
    }
  }
  self.adler = @adler32.INITIAL
  self.hdr_len = 0
  self.state = Data(inner)
}

///|
/// Gathers header or trailer bytes until `hdr` holds `n`.
fn Decoder::fill(self : Decoder, n : Int32) -> Unit raise Stop {
  let take = (n - self.hdr_len).min(self.view.length() - self.in_pos)
  if take > 0 {
    self.hdr.blit_from_bytesview(
      self.hdr_len,
      self.view[self.in_pos:self.in_pos + take],
    )
    self.hdr_len += take
    self.in_pos += take
  }
  if self.hdr_len < n {
    raise NeedInput
  }
}

///|
/// Records a terminal error and raises it.
fn[T] Decoder::fail(
  self : Decoder,
  err : @codec.CodecError,
) -> T raise @codec.CodecError {
  self.failure = Some(err)
  self.release_step()
  raise err
}

///|
/// Drops the caller's buffers so a suspended decoder holds neither.
fn Decoder::release_step(self : Decoder) -> Unit {
  self.view = b""[:]
  self.in_pos = 0
  self.out = self.empty_out.mut_view()
  self.fixed_out = None
  self.out_pos = 0
}

///|
pub impl @codec_bytes.Decode for Decoder with fn step(self, input, output, end~) {
  Decoder::step(self, input, output, end~)
}

///|
pub impl @codec_bytes.Decode for Decoder with fn last_consumed(self) {
  Decoder::last_consumed(self)
}

///|
pub impl @codec_bytes.Decode for Decoder with fn last_produced(self) {
  Decoder::last_produced(self)
}

///|
pub impl @codec_bytes.Decode for Decoder with fn reset(self) {
  Decoder::reset(self)
}

///|
pub impl @codec_bytes.Decode for Decoder with fn memory_usage(self) {
  Decoder::memory_usage(self)
}
