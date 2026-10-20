///|
/// Outcome of one `Decoder::step`, as in `moonbit-community/flate`.
pub(all) enum Status {
  /// The stream ended and every decoded byte has been handed out.
  Done
  /// The input is used up mid-stream; call again with more input.
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
#non_exhaustive
pub(all) enum BrotliErrorKind {
  /// The input ended before the last meta-block did.
  Truncated
  /// The stream breaks RFC 7932.
  Corrupt
  /// Bytes follow the end of the stream.
  TrailingData
  /// The stream declares a window larger than `max_window_bits` allows.
  WindowTooLarge
  /// `decompress` would produce more than `max_output` bytes.
  OutputLimitExceeded
} derive(Eq, Debug)

///|
pub extend BrotliErrorKind with Eq::{equal, not_equal}

///|
pub extend BrotliErrorKind with @debug.Debug::{to_repr}

///|
/// The error every decoding failure raises: a kind and a message.
pub suberror BrotliError {
  BrotliError(BrotliErrorKind, String)
} derive(Debug)

///|
pub extend BrotliError with @debug.Debug::{to_repr}

///|
/// Why a unit stopped early, inside the decoder.
priv suberror Stop {
  /// The unit needs bytes the input does not have yet.
  NeedInput
  /// The stream is refused.
  Fail(BrotliErrorKind, String)
}

///|
fn corrupt(message : String) -> Stop {
  Fail(Corrupt, message)
}
