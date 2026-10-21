// The streaming decoder.
//
// The decoding is `@inflate.Inflater`'s, which zlib and gzip hold too: it
// stops right after the final block, consuming nothing past it, and hands
// out every byte before an error before it raises. This type adds where a
// raw DEFLATE stream ends: under `EndOfInput`, `Done` waits for `end`, and a
// byte after the final block raises `TrailingData` (raw DEFLATE cannot be
// concatenated); under `EndOfMember`, `Done` comes right after the final
// block, and what follows is `input[last_consumed():]`.

///|
priv enum State {
  /// The final block has not ended.
  Running
  /// The final block has ended; under `EndOfInput`, `Done` waits for `end`.
  Ended
  /// `Done` was answered.
  Done
}

///|
/// The history window of RFC 1951: distances reach at most 32 KiB back.
const WINDOW_SIZE : Int32 = 32768

///|
/// A streaming raw DEFLATE decoder (RFC 1951). Feed it input in chunks of any
/// size with `step` and collect output in slices of any size; it holds the
/// 32 KiB window and the Huffman tables of the current block, never the whole
/// input or output.
pub struct Decoder {
  priv inflater : @inflate.Inflater
  // The last 32 KiB of the preset dictionary, all the window can use: a view
  // of the caller's bytes, which are immutable, for `reset`.
  priv dictionary : BytesView?
  priv until : @codec_bytes.Until
  priv mut state : State
  priv mut failure : @codec.CodecError?
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
}

///|
/// A decoder at the start of a stream.
///
/// `dictionary` is a preset dictionary: the stream's matches may reach back
/// into its last 32 KiB as if it had been decoded just before the stream. A
/// zlib stream names the one it needs; raw DEFLATE leaves it to the caller.
/// The decoder keeps a view of the dictionary's last 32 KiB, not a copy, so
/// the bytes the view belongs to stay alive as long as the decoder.
///
/// `until` says where the stream ends. `EndOfInput`, the default, decodes the
/// stream up to the end of the input, and bytes after its final block raise
/// `TrailingData`. `EndOfMember` stops right after the final block and
/// consumes nothing past it, so that `input[last_consumed():]` is what follows:
/// a format that embeds DEFLATE (zlib, gzip) reads its trailer from there.
pub fn Decoder::Decoder(
  dictionary? : BytesView,
  until~ : @codec_bytes.Until = EndOfInput,
) -> Decoder {
  let dictionary = dictionary.map(d => d[(d.length() - WINDOW_SIZE).max(0):])
  let inflater = @inflate.Inflater::new()
  inflater.reset(dictionary?)
  {
    inflater,
    dictionary,
    until,
    state: Running,
    failure: None,
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Starts a new stream with the same options: the same dictionary, and the
/// same `until`.
pub fn Decoder::reset(self : Decoder) -> Unit {
  self.inflater.reset(dictionary?=self.dictionary)
  self.state = Running
  self.failure = None
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// Bytes held for the stream: the 32 KiB window, the Huffman tables of a
/// block and the scratch space they are built with, and the bytes kept aside
/// for a unit cut short. All of it is allocated when the decoder is made, so
/// this is the same from the first step to the last, with a dictionary or
/// without (see RESOURCE_BOUNDS.md). A dictionary is the caller's bytes, kept
/// by reference, and not counted.
pub fn Decoder::memory_usage(self : Decoder) -> Int32 {
  self.inflater.memory_usage()
}

///|
/// Whether the stream has ended: its final block is decoded and all its
/// output has been handed out. Under `EndOfInput` this can be true before
/// `Done`, which waits for `end`.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  !(self.state is Running)
}

///|
/// Input bytes the latest `step` accepted: all of them on `NeedMoreInput`.
/// A step that raised accepted the bytes up to the error; for
/// `TrailingData`, exactly up to the end of the stream, or none if the
/// stream ended before this step's input.
pub fn Decoder::last_consumed(self : Decoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote, a step that raised included: the
/// output before the error.
pub fn Decoder::last_produced(self : Decoder) -> Int32 {
  self.step_produced
}

///|
/// Decodes from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used.
///
/// Pass `end=true` once `input` holds the last bytes and `end=false` before:
/// a stream cut short then raises `Truncated`. Under `until=EndOfInput` a
/// stream whose final block has ended answers `NeedMoreInput` until `end`,
/// and bytes after it raise `TrailingData`; under `until=EndOfMember` it
/// answers `Done` right after the final block, whatever `end` says. After an
/// error the decoder raises it again, consuming and writing nothing, until
/// `reset`.
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
  match self.state {
    Running => {
      let status = try {
        match fixed_output {
          Some(out) => self.inflater.step_into(input, out, end~)
          None => self.inflater.step(input, output, end~)
        }
      } catch {
        err =>
          self.fail(
            err,
            self.inflater.last_consumed(),
            self.inflater.last_produced(),
          )
      }
      let consumed = self.inflater.last_consumed()
      let produced = self.inflater.last_produced()
      match status {
        Done => {
          self.state = Ended
          self.ended(input, consumed, produced, end~)
        }
        NeedMoreInput | NeedMoreOutput =>
          self.finish(status, consumed, produced)
      }
    }
    Ended => self.ended(input, 0, 0, end~)
    Done => {
      if self.until is EndOfInput && input.length() > 0 {
        self.fail(
          CodecError(TrailingData, "data after the end of the stream"),
          0,
          0,
        )
      }
      self.finish(Done, 0, 0)
    }
  }
}

///|
/// The answer of a step in which the final block has ended, `consumed` bytes
/// into `input`.
fn Decoder::ended(
  self : Decoder,
  input : BytesView,
  consumed : Int32,
  produced : Int32,
  end~ : Bool,
) -> Status raise @codec.CodecError {
  match self.until {
    EndOfMember => {
      self.state = Done
      self.finish(Done, consumed, produced)
    }
    EndOfInput =>
      if consumed < input.length() {
        self.fail(
          CodecError(TrailingData, "data after the final block"),
          consumed,
          produced,
        )
      } else if end {
        self.state = Done
        self.finish(Done, consumed, produced)
      } else {
        self.finish(NeedMoreInput, consumed, produced)
      }
  }
}

///|
fn Decoder::finish(
  self : Decoder,
  status : Status,
  consumed : Int32,
  produced : Int32,
) -> Status {
  self.step_consumed = consumed
  self.step_produced = produced
  status
}

///|
/// Records a terminal error and raises it, from a step that consumed
/// `consumed` bytes and wrote `produced` before it.
fn[T] Decoder::fail(
  self : Decoder,
  err : @codec.CodecError,
  consumed : Int32,
  produced : Int32,
) -> T raise @codec.CodecError {
  self.failure = Some(err)
  self.step_consumed = consumed
  self.step_produced = produced
  raise err
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
