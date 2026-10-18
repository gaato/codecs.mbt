///|
/// Outcome of one `Decoder::step`, as in `moonbit-community/flate`.
pub(all) enum Status {
  /// The stream ended and every decoded byte has been handed out.
  Done
  /// The input is used up; call again with more input, or with `end=true`
  /// if there is none.
  NeedMoreInput
  /// Decoded bytes are waiting; call again with free output room.
  NeedMoreOutput
} derive(Eq, Debug)

///|
pub extend Status with Eq::{equal, not_equal}

///|
pub extend Status with @debug.Debug::{to_repr}

///|
/// Why a stream was refused.
pub(all) enum ZstdErrorKind {
  /// The input ended inside a frame, or held no frame at all.
  Truncated
  /// The stream breaks RFC 8878, or bytes after a frame start no frame.
  Corrupt
  /// A frame's content checksum does not match its decoded bytes.
  ChecksumMismatch
  /// A frame declares a window larger than `max_window_bits` allows.
  WindowTooLarge
  /// A frame names a dictionary; this decoder has none.
  DictionaryUnsupported
  /// `decompress` would produce more than `max_output` bytes.
  OutputLimitExceeded
} derive(Eq, Debug)

///|
pub extend ZstdErrorKind with Eq::{equal, not_equal}

///|
pub extend ZstdErrorKind with @debug.Debug::{to_repr}

///|
/// The error every decoding failure raises: a kind and a message.
pub suberror ZstdError {
  ZstdError(ZstdErrorKind, String)
} derive(Debug)

///|
pub extend ZstdError with @debug.Debug::{to_repr}

///|
/// Why a unit stopped early, inside the decoder.
priv suberror Stop {
  /// The unit needs bytes the input does not have yet.
  NeedInput
  /// The stream is refused.
  Fail(ZstdErrorKind, String)
}

///|
fn corrupt(message : String) -> Stop {
  Fail(Corrupt, message)
}
