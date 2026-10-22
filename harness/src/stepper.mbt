///|
/// Why a step stopped, as the checks see it. Byte streams stop for input,
/// for output room, at the end or at an error; kinds whose output has
/// structure (an image's header, its rows) also stop at events, which the
/// checks compare as text.
pub(all) enum Stop {
  NeedMoreInput
  NeedMoreOutput
  Event(String)
  /// The step wrote output and stopped for no reason the checks compare:
  /// how many rows an image decoder's step writes depends on the room, so
  /// it is not part of a transcript.
  Wrote
  Done
  /// The step raised this kind of `CodecError`, with this message, after
  /// consuming and producing what the step says.
  Raised(@codec.ErrorKind, String)
} derive(Eq, @debug.Debug)

///|
pub extend Stop with Eq::{equal, not_equal}

///|
pub extend Stop with @debug.Debug::{to_repr}

///|
/// What one step did: input bytes it consumed, output it produced, and why
/// it stopped.
pub(all) struct Step {
  consumed : Int32
  produced : Bytes
  stop : Stop
}

///|
/// A codec of any kind, seen through the checks' common lens: given input
/// and room for output, take a step. A kind's adapter (`ByteDecoder` for
/// byte streams, `ImageDecoder` for images) turns its contract into this,
/// and checks its own rules on the way; a contract violation raises
/// `Failure`, and a codec error ends the step with `Raised`, which keeps
/// what the step consumed and produced before it.
pub(open) trait Stepper {
  fn step(Self, BytesView, Int32, end~ : Bool) -> Step raise
  fn reset(Self) -> Unit
  fn memory_usage(Self) -> Int32
}

///|
/// A byte-stream decoder under the checks.
pub struct ByteDecoder[D] {
  decoder : D
}

///|
pub fn[D] ByteDecoder::new(decoder : D) -> ByteDecoder[D] {
  { decoder, }
}

///|
pub extend ByteDecoder with Stepper::{step, reset, memory_usage}

///|
pub impl[D : @codec_bytes.Decode] Stepper for ByteDecoder[D] with fn step(
  self,
  input,
  room,
  end~,
) {
  let out = FixedArray::make(room, b'\x00')
  let stop : Stop = try self.decoder.step(input, out.mut_view(), end~) catch {
    @codec.CodecError(kind, message) => Raised(kind, message)
  } noraise {
    Done => Done
    NeedMoreInput => NeedMoreInput
    NeedMoreOutput => NeedMoreOutput
  }
  to_step(
    stop,
    input,
    out,
    self.decoder.last_consumed(),
    self.decoder.last_produced(),
  )
}

///|
/// A byte-stream step as the checks see it, once its counts are checked
/// against what it was given (a step that raised too reports what it
/// consumed and produced before the error, within what it was given), and a
/// full slice is checked to be full.
fn to_step(
  stop : Stop,
  input : BytesView,
  out : FixedArray[Byte],
  consumed : Int32,
  produced : Int32,
) -> Step raise {
  check_counts(input, out.length(), consumed, produced)
  if stop is NeedMoreOutput && produced != out.length() {
    fail("NeedMoreOutput with \{out.length() - produced} bytes of room left")
  }
  { consumed, produced: Bytes::from_array(out[:produced]), stop, }
}

///|
/// Fails unless a step given `input` and `room` bytes of output consumed and
/// produced within them.
fn check_counts(
  input : BytesView,
  room : Int32,
  consumed : Int32,
  produced : Int32,
) -> Unit raise {
  if consumed < 0 || consumed > input.length() {
    fail("consumed \{consumed} of \{input.length()} bytes")
  }
  if produced < 0 || produced > room {
    fail("produced \{produced} bytes into \{room}")
  }
}

///|
pub impl[D : @codec_bytes.Decode] Stepper for ByteDecoder[D] with fn reset(self) {
  self.decoder.reset()
}

///|
pub impl[D : @codec_bytes.Decode] Stepper for ByteDecoder[D] with fn memory_usage(
  self,
) {
  self.decoder.memory_usage()
}

///|
/// A byte-stream encoder under the checks. A step with `end` is a step with
/// `Finish`, any other a step with `Continue`, so that `drive` and every
/// check built on it run encoders as they run decoders: the output of a
/// run is the encoded stream.
pub struct ByteEncoder[E] {
  encoder : E
}

///|
pub fn[E] ByteEncoder::new(encoder : E) -> ByteEncoder[E] {
  { encoder, }
}

///|
pub extend ByteEncoder with Stepper::{step, reset, memory_usage}

///|
pub impl[E : @codec_bytes.Encode] Stepper for ByteEncoder[E] with fn step(
  self,
  input,
  room,
  end~,
) {
  encode_step(self.encoder, input, room, if end { Finish } else { Continue })
}

///|
pub impl[E : @codec_bytes.Encode] Stepper for ByteEncoder[E] with fn reset(self) {
  self.encoder.reset()
}

///|
pub impl[E : @codec_bytes.Encode] Stepper for ByteEncoder[E] with fn memory_usage(
  self,
) {
  self.encoder.memory_usage()
}

///|
/// One step of `encoder` with `action`, checked: besides the counts, `Done`
/// comes only after `Finish` with every byte of `input` consumed.
fn[E : @codec_bytes.Encode] encode_step(
  encoder : E,
  input : BytesView,
  room : Int32,
  action : @codec_bytes.EncodeAction,
) -> Step raise {
  let out = FixedArray::make(room, b'\x00')
  let stop : Stop = try encoder.step(input, out.mut_view(), action~) catch {
    @codec.CodecError(kind, message) => Raised(kind, message)
  } noraise {
    Done => Done
    NeedMoreInput => NeedMoreInput
    NeedMoreOutput => NeedMoreOutput
  }
  let step = to_step(
    stop,
    input,
    out,
    encoder.last_consumed(),
    encoder.last_produced(),
  )
  if step.stop is Done && (action != Finish || step.consumed != input.length()) {
    fail(
      "Done after \{@debug.to_string(action)} with \{input.length() - step.consumed} bytes unread",
    )
  }
  step
}
