///|
/// Why a codec stopped with an error. The same kinds serve every kind of
/// codec (byte streams, images, audio), so that callers handle a failure the
/// same way whatever they were decoding. New kinds may be added.
#derive(Eq, @debug.Debug)
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
}

///|
/// `ErrorKind::equal` and `ErrorKind::not_equal`, the derived comparison.
pub extend ErrorKind with Eq::{equal, not_equal}

///|
/// `ErrorKind::to_repr`, the derived debug representation.
pub extend ErrorKind with @debug.Debug::{to_repr}

///|
/// A limit a stream would exceed: what it is about, how much the stream needs
/// when that is known, and how much is allowed. Amounts are in the
/// resource's unit (bytes for memory and output).
#derive(Eq, @debug.Debug)
pub(all) struct Limit {
  resource : Resource
  needed : UInt64?
  limit : UInt64
}

///|
/// `Limit::equal` and `Limit::not_equal`, the derived comparison.
pub extend Limit with Eq::{equal, not_equal}

///|
/// `Limit::to_repr`, the derived debug representation.
pub extend Limit with @debug.Debug::{to_repr}

///|
/// What a limit is about. New resources may be added.
#derive(Eq, @debug.Debug)
#non_exhaustive
pub(all) enum Resource {
  /// Bytes the codec allocates for a stream (windows, tables, buffers).
  Memory
  /// Bytes of output.
  Output
}

///|
/// `Resource::equal` and `Resource::not_equal`, the derived comparison.
pub extend Resource with Eq::{equal, not_equal}

///|
/// `Resource::to_repr`, the derived debug representation.
pub extend Resource with @debug.Debug::{to_repr}

///|
/// The error every codec raises through its kind's contract: a kind to act
/// on, and a message for people.
#derive(@debug.Debug)
pub(all) suberror CodecError {
  CodecError(ErrorKind, String)
}

///|
/// `CodecError::to_repr`, the derived debug representation.
pub extend CodecError with @debug.Debug::{to_repr}

///|
/// The kind of the error.
pub fn CodecError::kind(self : CodecError) -> ErrorKind {
  match self {
    CodecError(kind, _) => kind
  }
}
