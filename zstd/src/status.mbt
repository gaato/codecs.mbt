///|
/// Outcome of one `Decoder::step`: `Done`, `NeedMoreInput` or
/// `NeedMoreOutput`, as every `gaato/codec_bytes` decoder answers.
pub using @codec_bytes {type Status}

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
