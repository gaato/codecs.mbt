///|
/// Why a codec stopped with an error. The same kinds serve every kind of
/// codec (byte streams, images, audio), so that callers handle a failure the
/// same way whatever they were decoding. New kinds may be added.
#non_exhaustive
pub(all) enum ErrorKind {
  /// The input ended inside a stream.
  Truncated
  /// The input is not a valid stream.
  Corrupt
  /// A checksum, or a length the stream declares, does not match the data.
  ChecksumMismatch
  /// Bytes follow the end of the stream.
  TrailingData
  /// Going on would exceed a limit.
  LimitExceeded(Limit)
  /// The stream needs a dictionary, identified by its id when it has one.
  DictionaryRequired(UInt32?)
  /// The dictionary given is not the one the stream needs.
  DictionaryMismatch
  /// The stream is valid, but uses something this codec does not implement,
  /// or the caller asked for something the format cannot do.
  Unsupported
} derive(Eq, @debug.Debug)

///|
pub extend ErrorKind with Eq::{equal, not_equal}

///|
pub extend ErrorKind with @debug.Debug::{to_repr}

///|
/// A limit a stream would exceed: what it is about, how much the stream needs
/// when that is known, and how much is allowed. Amounts are in the
/// resource's unit (bytes for memory and output).
pub(all) struct Limit {
  resource : Resource
  needed : UInt64?
  limit : UInt64
} derive(Eq, @debug.Debug)

///|
pub extend Limit with Eq::{equal, not_equal}

///|
pub extend Limit with @debug.Debug::{to_repr}

///|
/// What a limit is about. New resources may be added.
#non_exhaustive
pub(all) enum Resource {
  /// Bytes the codec allocates for a stream (windows, tables, buffers).
  Memory
  /// Bytes of output.
  Output
} derive(Eq, @debug.Debug)

///|
pub extend Resource with Eq::{equal, not_equal}

///|
pub extend Resource with @debug.Debug::{to_repr}

///|
/// The error every codec raises through its kind's contract: a kind to act
/// on, and a message for people.
pub(all) suberror CodecError {
  CodecError(ErrorKind, String)
} derive(@debug.Debug)

///|
pub extend CodecError with @debug.Debug::{to_repr}

///|
/// The kind of the error.
pub fn CodecError::kind(self : CodecError) -> ErrorKind {
  match self {
    CodecError(kind, _) => kind
  }
}
