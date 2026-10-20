///|
/// Why a step stopped, as the checks see it. Byte streams stop for input,
/// for output room or at the end; kinds whose output has structure (an
/// image's header, its rows) also stop at events, which the checks compare
/// as text.
pub(all) enum Stop {
  NeedMoreInput
  NeedMoreOutput
  Event(String)
  Done
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
/// byte streams) turns its contract into this, and checks its own rules on
/// the way; a contract violation raises `Failure`, a codec error raises
/// `CodecError`.
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
  let status = self.decoder.step(input, out.mut_view(), end~) catch {
    @codec.CodecError(kind, message) => {
      // A step that raises reports nothing consumed and nothing produced.
      if self.decoder.last_consumed() != 0 || self.decoder.last_produced() != 0 {
        fail(
          "a raising step reported \{self.decoder.last_consumed()} consumed and \{self.decoder.last_produced()} produced",
        )
      }
      raise @codec.CodecError(kind, message)
    }
  }
  let consumed = self.decoder.last_consumed()
  let produced = self.decoder.last_produced()
  if consumed < 0 || consumed > input.length() {
    fail("consumed \{consumed} of \{input.length()} bytes")
  }
  if produced < 0 || produced > room {
    fail("produced \{produced} bytes into \{room}")
  }
  let stop : Stop = match status {
    Done => Done
    NeedMoreInput => NeedMoreInput
    NeedMoreOutput => NeedMoreOutput
  }
  { consumed, produced: Bytes::from_array(out[:produced]), stop, }
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
