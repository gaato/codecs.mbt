///|
/// Outcome of one `Decoder::step` or `Encoder::step`: `Done`,
/// `NeedMoreInput` or `NeedMoreOutput`, as every `gaato/codec_bytes` codec
/// answers.
pub using @codec_bytes {type Status}

///|
/// What `Encoder::step` does once its input is taken: `Continue`, `Flush`
/// or `Finish`, as every `gaato/codec_bytes` encoder takes it.
pub using @codec_bytes {type EncodeAction}

///|
/// Why a unit stopped early, inside the decoder.
priv suberror Stop {
  /// The unit needs bytes the input does not have yet.
  NeedInput
  /// The stream is refused.
  Fail(@codec.ErrorKind, String)
}

///|
fn corrupt(message : String) -> Stop {
  Fail(Corrupt, message)
}

///|
/// The value of one of `@header`'s pure checks, or corruption with its
/// message.
fn[T] checked(result : Result[T, String]) -> T raise Stop {
  match result {
    Ok(value) => value
    Err(message) => raise corrupt(message)
  }
}
