// The streaming decoder.
//
// The decoding is moonbit-community/flate's raw `Inflater`; this type holds it
// to `gaato/codec_bytes`'s contract where the inflater's own rules differ, and
// keeps every flate type out of the public signatures, so that a decoder of
// this module's own can take its place without breaking anyone.
//
// What the inflater does, and what is done here about it:
//
// - It never takes a whole byte past the final block: a unit reads bytes only
//   as its bits need them, the native fast path gives back the bytes it loaded
//   ahead, and the bytes it keeps aside for an unfinished unit all belong to
//   that unit. So under `EndOfMember` what follows the stream is
//   `input[last_consumed():]`, and under `EndOfInput` any of it is
//   `TrailingData` (raw DEFLATE cannot be concatenated). The tests check it
//   under every split.
// - It answers `Done` as soon as the final block ends, whatever `end` says.
//   Under `EndOfInput` the contract wants `Done` only with `end`: until then,
//   a stream that has ended answers `NeedMoreInput`, and a byte that arrives
//   after it raises `TrailingData`.
// - It raises its own `InflateError`, which is turned into `gaato/codec`'s
//   `CodecError` and kept here, so that the error sticks as the contract
//   says, in this type's terms.
// - A step that raises reports nothing consumed or produced, though it may
//   have written into the caller's slice. The contract wants the counts of a
//   step that raises, so the inflater is never told `end`: a stream cut
//   short is found here, when the inflater asks for more input after the
//   end, with its counts. Only a `Corrupt` inside the DEFLATE data, found by
//   the inflater, still reports nothing (README, known limits).
// - It refuses what zlib refuses, with zlib's kind of error, with two
//   exceptions found by the crafted streams (src/vectors_wbtest.mbt): a
//   dynamic block without an end-of-block code is refused only when the
//   input runs out (`Truncated`), where zlib refuses its header (`Corrupt`);
//   and an all-zero code-length code is `Corrupt` at once, where zlib reads a
//   length of zero from every bit and asks for more input.
// - It writes straight into the caller's slice and holds no decoded byte
//   back, so `NeedMoreInput` means everything is out and `Done` leaves
//   nothing pending.

///|
priv enum State {
  /// The inflater is inside the stream.
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
/// The most the inflater's second-level Huffman tables hold, in bytes. A
/// table has second-level entries only for codes longer than 9 bits: 64
/// entries of 4 bytes for each 9-bit prefix they start with, and each such
/// prefix holds at least two codes, so at most 143 prefixes for the 286
/// literal/length codes and 15 for the 30 distance codes.
const LINK_TABLE_BYTES : Int32 = (143 + 15) * 64 * 4

///|
/// The most bytes the inflater keeps aside for a unit that the input cut
/// short: the longest unit, a dynamic block header, is at most 2,286 bits
/// (286 bytes), held in an array of at most twice that.
const STAGED_BYTES : Int32 = 1024

///|
/// A streaming raw DEFLATE decoder (RFC 1951). Feed it input in chunks of any
/// size with `step` and collect output in slices of any size; it holds the
/// 32 KiB window and the Huffman tables of the current block, never the whole
/// input or output.
///
/// It is built on moonbit-community/flate's inflater today.
pub struct Decoder {
  priv inflater : @flate.Inflater
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
  {
    inflater: match dictionary {
      Some(d) => @flate.Inflater(dictionary=d)
      None => @flate.Inflater()
    },
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
  match self.dictionary {
    Some(d) => self.inflater.reset(dictionary=d)
    None => self.inflater.reset()
  }
  self.state = Running
  self.failure = None
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// Bytes held for the stream, as an upper bound: the 32 KiB window, the
/// second-level Huffman tables of the current block (at most 40,448 bytes)
/// and the bytes kept aside for a unit cut short (at most 1 KiB). The
/// inflater does not say how much of its tables a block uses, so this is the
/// same from the first step to the last: 74,240 bytes, with a dictionary or
/// without. A dictionary is the caller's bytes, kept by reference, and not
/// counted.
pub fn Decoder::memory_usage(_ : Decoder) -> Int32 {
  WINDOW_SIZE + LINK_TABLE_BYTES + STAGED_BYTES
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
/// stream ended before this step's input. Zero after a `Corrupt` found
/// inside the DEFLATE data (README, known limits).
pub fn Decoder::last_consumed(self : Decoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote, a step that raised included: the
/// output before the error. Zero after a `Corrupt` found inside the DEFLATE
/// data, which may follow output written into the slice (README, known
/// limits).
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
      // Without `end`, the inflater never raises `Truncated`, which would
      // lose the step's counts; a cut is found below instead.
      let status = try {
        match fixed_output {
          Some(out) => self.inflater.step_into(input, out, end=false)
          None => self.inflater.step(input, output, end=false)
        }
      } catch {
        // Without `end`, a step raises only `Corrupt`: the inflater's other
        // kinds come from its one-shot functions, not used here. It does not
        // say what this step consumed and wrote.
        @flate.InflateError(_, message) =>
          self.fail(CodecError(Corrupt, plain(message)), 0, 0)
      }
      let consumed = self.inflater.last_consumed()
      let produced = self.inflater.last_produced()
      match status {
        Done => {
          self.state = Ended
          self.ended(input, consumed, produced, end~)
        }
        NeedMoreInput if end =>
          self.fail(
            CodecError(Truncated, "unexpected end of input"),
            consumed,
            produced,
          )
        NeedMoreInput => self.finish(NeedMoreInput, consumed, produced)
        NeedMoreOutput => self.finish(NeedMoreOutput, consumed, produced)
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
/// An inflater message without its "corrupt: " prefix, which the error kind
/// already says.
fn plain(message : String) -> String {
  match message.strip_prefix("corrupt: ") {
    Some(rest) => rest.to_owned()
    None => message
  }
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
