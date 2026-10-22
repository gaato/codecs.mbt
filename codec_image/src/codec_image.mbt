///|
/// The error every codec raises, its kinds, and the limits a stream can
/// exceed, from `gaato/codec`, so that a caller of an image decoder can name
/// them with this package as its only import. A constructor is matched
/// unqualified, as in `CodecError(Corrupt, _)`, where the type is known (a
/// `catch` on a decoder's step), or qualified by its type, as in
/// `@codec_image.CodecError::CodecError(kind, _)`.
pub using @codec {type CodecError, type ErrorKind, type Limit, type Resource}

///|
/// Why a step stopped without an error. Every step that writes output says
/// what it wrote (`Rows`, `Metadata`); every other answer comes from a step
/// that wrote nothing.
pub(all) enum Status {
  /// The image's header is read: `width` and `height` are known, and so is
  /// everything the format's own type reports about the header. Comes once,
  /// before any frame.
  Header
  /// A frame begins: its rectangle is known (`frame_x`, `frame_y`,
  /// `frame_width`, `frame_height`). A still image is one frame.
  Frame
  /// Whole rows of one pass of the current frame were written:
  /// `rows_count` rows of `row_bytes` bytes each, starting at row
  /// `rows_first` of pass `pass`.
  Rows
  /// A block of metadata the decoder was asked for was written whole. What
  /// it is, the format's own type says.
  Metadata
  /// The frame's last row was written, and every check covering its data
  /// (checksums, lengths) has passed.
  FrameEnd
  /// The image is complete (see `Until`).
  Done
  /// Every input byte was consumed, and every row and every event it
  /// determines has been delivered.
  NeedMoreInput
  /// The output slice cannot hold the next row or block of metadata, whose
  /// size `room_needed` says. Nothing was written.
  NeedMoreOutput
} derive(Eq, @debug.Debug)

///|
pub extend Status with Eq::{equal, not_equal}

///|
pub extend Status with @debug.Debug::{to_repr}

///|
/// Where a decoder stops when bytes follow the image.
pub(all) enum Until {
  /// Decode the image up to the end of the input; bytes after it are an
  /// error.
  EndOfInput
  /// Stop right after the image and leave the rest unread.
  EndOfMember
} derive(Eq, @debug.Debug)

///|
pub extend Until with Eq::{equal, not_equal}

///|
pub extend Until with @debug.Debug::{to_repr}

///|
/// A decoder of an image read from a byte stream, driven step by step.
///
/// A step consumes a prefix of `input` and writes a prefix of `output`
/// (`last_consumed` and `last_produced` say how much), and returns why it
/// stopped. `end` says whether `input` reaches the end of the data. The rules
/// every decoder keeps are in the repository's CONTRACT.md: among them, a
/// decoder writes whole rows only, and all rows of one step belong to one
/// pass of one frame; it reports every event and writes every row the input
/// determines before it raises; errors stick until `reset`; and the rows,
/// the metadata, the events and the error do not depend on how input and
/// output are split.
///
/// The numbers that describe what a step reported are read from the
/// decoder, never returned as a tuple or a struct. Each says when it is
/// valid; outside that, its value is unspecified.
pub(open) trait Decode {
  fn step(Self, BytesView, MutArrayView[Byte], end~ : Bool) -> Status raise @codec.CodecError
  /// Input bytes consumed by the last step, one that raised included: what it
  /// consumed before the error. For `TrailingData`, exactly up to the end of
  /// the image (zero if it ended before this step's input). Zero for the
  /// steps after an error.
  fn last_consumed(Self) -> Int32
  /// Output bytes written by the last step: those of its rows or of its
  /// block of metadata, and zero for every other answer, an error included.
  fn last_produced(Self) -> Int32
  /// Returns the decoder to the state of a new one with the same options.
  fn reset(Self) -> Unit
  /// Bytes the decoder has allocated for the current image.
  fn memory_usage(Self) -> Int32
  /// The smallest output slice with which the next step can write. After
  /// `NeedMoreOutput`, exactly the size of the row or the block of metadata
  /// that is waiting. After any other answer, the size of the next unit of
  /// output if the decoder has it ready or knows it (the next row of the
  /// current pass), and zero when it does not know yet.
  fn room_needed(Self) -> Int32
  /// The width of the image (its canvas), in pixels. Valid from `Header`
  /// until `reset`.
  fn width(Self) -> Int32
  /// The height of the image (its canvas), in pixels. Valid from `Header`
  /// until `reset`.
  fn height(Self) -> Int32
  /// The left edge of the current frame on the canvas. Valid from `Frame`
  /// until the next `Frame` or `Done`.
  fn frame_x(Self) -> Int32
  /// The top edge of the current frame on the canvas. Valid from `Frame`
  /// until the next `Frame` or `Done`.
  fn frame_y(Self) -> Int32
  /// The width of the current frame, in pixels. Valid from `Frame` until
  /// the next `Frame` or `Done`.
  fn frame_width(Self) -> Int32
  /// The height of the current frame, in pixels. Valid from `Frame` until
  /// the next `Frame` or `Done`.
  fn frame_height(Self) -> Int32
  /// The pass the last `Rows` belong to, counted from 0. An image that is
  /// not interlaced has the one pass 0. Valid after `Rows`, until the next
  /// step.
  fn pass(Self) -> Int32
  /// The column of the frame where the pass's pixels begin: pixel `i` of a
  /// row of the pass lies at column `pass_x + i * pass_dx` of the frame.
  /// Valid after `Rows`, until the next step.
  fn pass_x(Self) -> Int32
  /// The row of the frame where the pass's rows begin: row `r` of the pass
  /// lies at row `pass_y + r * pass_dy` of the frame. Valid after `Rows`,
  /// until the next step.
  fn pass_y(Self) -> Int32
  /// The distance between the columns of the pass's pixels, at least 1.
  /// Valid after `Rows`, until the next step.
  fn pass_dx(Self) -> Int32
  /// The distance between the rows of the pass, at least 1. Valid after
  /// `Rows`, until the next step.
  fn pass_dy(Self) -> Int32
  /// The row of the pass where the last `Rows` begin, counted from 0. Valid
  /// after `Rows`, until the next step.
  fn rows_first(Self) -> Int32
  /// How many rows the last `Rows` wrote, at least 1. Valid after `Rows`,
  /// until the next step.
  fn rows_count(Self) -> Int32
  /// The bytes of each row the last `Rows` wrote, at least 1; the step wrote
  /// `rows_count * row_bytes` bytes, rows one after another with nothing
  /// between them. Valid after `Rows`, until the next step.
  fn row_bytes(Self) -> Int32
}
