///|
/// `Status` and `EncodeAction` are gaato/codec_bytes's: a step answers
/// `Done`, `NeedMoreInput` or `NeedMoreOutput`, and an encoder's step is
/// told to `Continue`, `Flush` or `Finish`. Errors are gaato/codec's
/// `CodecError(kind, message)`.
pub using @codec_bytes {type Status, type EncodeAction}

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
/// The window a stream with `wbits` declares, in bytes: RFC 7932 section
/// 9.1's `(1 << WBITS) - 16`. Window limits are reported in these terms.
fn window_size(wbits : Int32) -> Int32 {
  (1 << wbits) - 16
}
