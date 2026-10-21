///|
/// Outcome of one `Decoder::step` or `Encoder::step`: `Done`,
/// `NeedMoreInput` or `NeedMoreOutput`, and what an encoder's step is told
/// to do: `Continue`, `Flush` or `Finish`, as every `gaato/codec_bytes`
/// codec answers and is told.
pub using @codec_bytes {type Status, type EncodeAction}

///|
/// Why a step stopped early, inside the decoder.
priv suberror Stop {
  /// A header, a trailer or the bytes between members need bytes the input does not have yet.
  NeedInput
  /// The stream is refused.
  Fail(@codec.ErrorKind, String)
}

///|
/// The value of one of `@header`'s pure checks, or a refusal of `kind` with
/// its message.
fn[T] checked(
  result : Result[T, String],
  kind~ : @codec.ErrorKind = Corrupt,
) -> T raise Stop {
  match result {
    Ok(value) => value
    Err(message) => raise Fail(kind, message)
  }
}
