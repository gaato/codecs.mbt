// The streaming encoder.
//
// The compression is `@deflater.Deflater`'s (src/internal/deflate), which zlib
// and gzip hold too: libdeflate's levels made streaming, with a sync flush
// and a preset dictionary. This type holds it to `gaato/codec_bytes`'s
// contract:
//
// - Its output does not depend on how the input and the output are split
//   (rule 5): where blocks end and what each one holds depend only on the
//   bytes, the level, the dictionary and where the flushes fall, and output
//   is handed out by copying it (src/internal/deflate/deflater.mbt says how).
// - It never raises: every input has an encoding, and a sync flush is always
//   possible.
// - Its arrays are allocated when it is made, with sizes fixed by the level,
//   so `memory_usage` is the same from the first step to the last
//   (RESOURCE_BOUNDS.md).

///|
/// A streaming raw DEFLATE encoder (RFC 1951). Feed it input in chunks of any
/// size with `step` and collect output in slices of any size; it holds the
/// 32 KiB window, a block of input and its output, and fixed-size match
/// tables, never the whole input or output.
pub struct Encoder {
  priv deflater : @deflater.Deflater
}

///|
/// An encoder at the start of a stream.
///
/// `level` trades speed for size as zlib's levels do: 0 writes the input in
/// stored blocks, 1 is the fastest compression, 9 the smallest, and 6, the
/// default, a balance. Levels outside 0 to 9 are clamped. The levels are
/// libdeflate's.
///
/// `dictionary` is a preset dictionary: the stream's matches may reach back
/// into its last 32 KiB as if it had come just before the stream, and the
/// decoder must be given the same one. The encoder keeps a view of the
/// dictionary's last 32 KiB, not a copy, so the bytes the view belongs to
/// stay alive as long as the encoder.
pub fn Encoder::Encoder(level~ : Int32 = 6, dictionary? : BytesView) -> Encoder {
  { deflater: @deflater.Deflater::new(level~, dictionary?), }
}

///|
/// Starts a new stream with the same options: the same level and the same
/// dictionary.
pub fn Encoder::reset(self : Encoder) -> Unit {
  self.deflater.reset()
}

///|
/// Bytes held for the stream, the same from the first step to the last: the
/// input buffer (the 32 KiB window, a block of up to 64 KiB and the 6 KiB
/// the parser looks ahead), the output of a block, the match finder's tables
/// and the block's sequences, counts and codes. 542,516 bytes at levels 5 to
/// 9, 542,172 at 2 to 4, 361,948 at 1 and 131,077 at 0, with a dictionary or
/// without. A dictionary is the caller's bytes, kept by reference, and not
/// counted.
pub fn Encoder::memory_usage(self : Encoder) -> Int32 {
  self.deflater.memory_usage()
}

///|
/// Whether the stream has ended and all its output has been handed out.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.deflater.is_finished()
}

///|
/// Input bytes the latest `step` took.
pub fn Encoder::last_consumed(self : Encoder) -> Int32 {
  self.deflater.last_consumed()
}

///|
/// Output bytes the latest `step` wrote.
pub fn Encoder::last_produced(self : Encoder) -> Int32 {
  self.deflater.last_produced()
}

///|
/// Compresses from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used. Input that was not taken
/// (when the output is full) must be passed again, with the same action.
///
/// `action` applies once all of `input` is taken: `Continue` only takes
/// input; `Flush` is a sync flush, as zlib's `Z_SYNC_FLUSH`: it compresses
/// everything taken and ends with an empty stored block (`00 00 ff ff`), so
/// that the output so far decodes to the input so far, and the stream goes
/// on; `Finish` ends the stream. A flush with nothing new since the last
/// one adds nothing. Both stay in effect while the step answers
/// `NeedMoreOutput`. Status: `NeedMoreInput` once everything is taken and
/// its output handed out (a `Flush` is then complete), `NeedMoreOutput`
/// while output waits, `Done` once the stream has ended and been handed
/// out; after that, steps take no input and answer `Done`.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  action~ : EncodeAction,
) -> Status {
  self.deflater.step(input, output, action~)
}

///|
/// `step` into a whole `FixedArray`.
pub fn Encoder::step_into(
  self : Encoder,
  input : BytesView,
  output : FixedArray[Byte],
  action~ : EncodeAction,
) -> Status {
  self.deflater.step_into(input, output, action~)
}

///|
/// The encoder never raises: every input has an encoding, and `Flush` is
/// always possible.
pub impl @codec_bytes.Encode for Encoder with fn step(
  self,
  input,
  output,
  action~,
) {
  Encoder::step(self, input, output, action~)
}

///|
/// Same as `Encoder::last_consumed`: input bytes the last step consumed.
pub impl @codec_bytes.Encode for Encoder with fn last_consumed(self) {
  Encoder::last_consumed(self)
}

///|
/// Same as `Encoder::last_produced`: output bytes the last step wrote.
pub impl @codec_bytes.Encode for Encoder with fn last_produced(self) {
  Encoder::last_produced(self)
}

///|
/// Same as `Encoder::reset`: back to the state of a new encoder with the same options.
pub impl @codec_bytes.Encode for Encoder with fn reset(self) {
  Encoder::reset(self)
}

///|
/// Same as `Encoder::memory_usage`: bytes allocated for the current stream.
pub impl @codec_bytes.Encode for Encoder with fn memory_usage(self) {
  Encoder::memory_usage(self)
}
