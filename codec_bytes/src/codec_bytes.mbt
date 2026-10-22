///|
/// The error every codec raises: `gaato/codec`'s, re-exported so that a caller
/// of a codec names it with this package as its only import. Its constructor
/// matches unqualified where the type is known, as in `CodecError(Corrupt, _)`
/// in a `catch` on a codec's step, or qualified by its type, as in
/// `@codec_bytes.CodecError::CodecError(kind, _)`.
pub using @codec {type CodecError}

///|
/// Why a codec stopped with an error: `gaato/codec`'s, re-exported.
pub using @codec {type ErrorKind}

///|
/// A limit a stream would exceed: `gaato/codec`'s, re-exported.
pub using @codec {type Limit}

///|
/// What a limit is about: `gaato/codec`'s, re-exported.
pub using @codec {type Resource}

///|
/// Why a step stopped without an error.
pub(all) enum Status {
  /// The stream is complete. With `Until::EndOfInput` this needs `end` and
  /// every input byte consumed; with `Until::EndOfMember`, nothing after the
  /// first member was consumed.
  Done
  /// Every input byte was consumed, and everything it determines was written.
  NeedMoreInput
  /// The output slice is full.
  NeedMoreOutput
} derive(Eq, @debug.Debug)

///|
/// `Status::equal` and `Status::not_equal`, the derived comparison.
pub extend Status with Eq::{equal, not_equal}

///|
/// `Status::to_repr`, the derived debug representation.
pub extend Status with @debug.Debug::{to_repr}

///|
/// Where a decoder stops, for formats whose streams can follow one another.
pub(all) enum Until {
  /// Decode every member up to the end of the input; bytes after the last
  /// member are an error.
  EndOfInput
  /// Stop right after the first member and leave the rest unread.
  EndOfMember
} derive(Eq, @debug.Debug)

///|
/// `Until::equal` and `Until::not_equal`, the derived comparison.
pub extend Until with Eq::{equal, not_equal}

///|
/// `Until::to_repr`, the derived debug representation.
pub extend Until with @debug.Debug::{to_repr}

///|
/// What an encoder's step should do with the input it has.
pub(all) enum EncodeAction {
  /// Compress as convenient; output may lag behind input.
  Continue
  /// Make everything so far decodable without ending the stream.
  Flush
  /// End the stream.
  Finish
} derive(Eq, @debug.Debug)

///|
/// `EncodeAction::equal` and `EncodeAction::not_equal`, the derived comparison.
pub extend EncodeAction with Eq::{equal, not_equal}

///|
/// `EncodeAction::to_repr`, the derived debug representation.
pub extend EncodeAction with @debug.Debug::{to_repr}

///|
/// A decoder of a byte stream, driven step by step.
///
/// A step consumes a prefix of `input` and writes a prefix of `output`
/// (`last_consumed` and `last_produced` say how much), and returns why it
/// stopped. `end` says whether `input` reaches the end of the data. The rules
/// every decoder keeps are in the repository's CONTRACT.md: among them, a
/// step that raises first writes all the output the input determines before
/// the error (answering `NeedMoreOutput` if the slice fills first) and
/// reports what it consumed and wrote, errors stick until `reset`, and the
/// output and the error do not depend on how input and output are split.
pub(open) trait Decode {
  fn step(Self, BytesView, MutArrayView[Byte], end~ : Bool) -> Status raise @codec.CodecError
  /// Input bytes consumed by the last step, one that raised included: what it
  /// consumed before the error. For `TrailingData`, exactly up to the end of
  /// the stream (zero if it ended before this step's input). Zero for the
  /// steps after an error.
  fn last_consumed(Self) -> Int32
  /// Output bytes written by the last step, one that raised included: what it
  /// wrote before the error. Zero for the steps after an error.
  fn last_produced(Self) -> Int32
  /// Returns the decoder to the state of a new one with the same options.
  fn reset(Self) -> Unit
  /// Bytes the decoder has allocated for the current stream.
  fn memory_usage(Self) -> Int32
}

///|
/// An encoder of a byte stream, driven step by step, with the same rules as
/// `Decode`; `action` takes the place of `end`.
pub(open) trait Encode {
  fn step(Self, BytesView, MutArrayView[Byte], action~ : EncodeAction) -> Status raise @codec.CodecError
  /// Input bytes consumed by the last step, one that raised included: what it
  /// consumed before the error. Zero for the steps after an error.
  fn last_consumed(Self) -> Int32
  /// Output bytes written by the last step, one that raised included: what it
  /// wrote before the error. Zero for the steps after an error.
  fn last_produced(Self) -> Int32
  /// Returns the encoder to the state of a new one with the same options.
  fn reset(Self) -> Unit
  /// Bytes the encoder has allocated for the current stream.
  fn memory_usage(Self) -> Int32
}
