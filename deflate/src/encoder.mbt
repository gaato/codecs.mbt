// The streaming encoder.
//
// The compression is moonbit-community/flate's `Deflater`; this type holds it
// to `gaato/codec_bytes`'s contract and keeps every flate type out of the
// public signatures, so that an encoder of this module's own can take its
// place without breaking anyone.
//
// What the deflater does, from flate 0.9.0's source (`deflate.mbt`,
// `block_planner.mbt`), and why it keeps the contract as it is:
//
// - Its output does not depend on how the input and the output are split
//   (rule 5). A step takes input only until 16,642 bytes wait (a 16 KiB block
//   and the 258 bytes a match may look ahead), and writes a block only when
//   exactly that much waits, or at a `Flush` or `Finish`, which it takes only
//   once the step's whole input is taken. Where blocks begin and end, and
//   what each block's parse sees, so depend only on the bytes and on where
//   the flushes fall. It writes a block only once the caller has taken all
//   of the previous one, and handing out output only copies it. The
//   conformance suite and the tests here check this under every split, so
//   no buffer of this type's own is needed to feed the deflater evenly.
// - It never raises: every input has an encoding, and a sync flush is always
//   possible.
// - Its arrays have fixed sizes, apart from the tokens of one block and the
//   output of one or two blocks, which grow up to a bound (RESOURCE_BOUNDS.md):
//   `memory_usage` reports the sum of the bounds below, which
//   scripts/flate_bounds.mbtx checks against the deflater's arrays.

///|
/// The deflater's input ring: 64 KiB, mirrored (`STREAM_RING_STORAGE_SIZE`).
const RING_BYTES : Int32 = 2 * 65536

///|
/// The deflater's match finder: the 3-byte heads (32,768 entries of 4
/// bytes), the 4-byte hash heads (65,536 entries of 4 bytes), and the
/// backward distances of the 32 KiB window (2 bytes each, and 2 more).
const FINDER_BYTES : Int32 = 32768 * 4 + 65536 * 4 + (2 * 32768 + 2)

///|
/// The deflater's tokens: one for each literal or match that begins inside a
/// block, which covers at most 16 KiB (a match may run past it, adding no
/// token), so at most 16,384, in an array whose capacity doubles from 8:
/// 16,384 entries of 4 bytes.
const TOKEN_BYTES : Int32 = 16384 * 4

///|
/// The deflater's output waiting for the caller: at most the encoding of the
/// input that waits, 16,642 bytes (a 16 KiB block and the 258 bytes of
/// look-ahead), in at most two blocks that each cost no more than stored
/// ones (5 bytes of framing and a byte of padding), and the empty stored
/// block of a flush: 16,660 bytes, in an array whose capacity doubles from
/// 8: 32,768 bytes.
const OUTPUT_BYTES : Int32 = 32768

///|
/// The deflater's symbol counts: 286 literal/length and 30 distance codes,
/// 4 bytes each.
const FREQ_BYTES : Int32 = (286 + 30) * 4

///|
/// What `Encoder::memory_usage` reports: 689,394 bytes.
const ENCODER_BYTES : Int32 = RING_BYTES +
  FINDER_BYTES +
  TOKEN_BYTES +
  OUTPUT_BYTES +
  FREQ_BYTES

///|
/// A streaming raw DEFLATE encoder (RFC 1951). Feed it input in chunks of
/// any size with `step` and collect output in slices of any size; it holds
/// the 32 KiB window, a block of input and its output, and fixed-size match
/// tables, never the whole input or output.
///
/// It is built on moonbit-community/flate's deflater today.
pub struct Encoder {
  priv deflater : @flate.Deflater
  // The last 32 KiB of the preset dictionary, all the window can use: a view
  // of the caller's bytes, which are immutable, for `reset`.
  priv dictionary : BytesView?
}

///|
/// An encoder at the start of a stream.
///
/// `level` trades speed for size as zlib's levels do: 0 writes the input in
/// stored blocks, 1 is the fastest compression, 9 the smallest, and 6, the
/// default, a balance. Levels outside 0 to 9 are clamped.
///
/// `dictionary` is a preset dictionary: the stream's matches may reach back
/// into its last 32 KiB as if it had come just before the stream, and the
/// decoder must be given the same one. The encoder keeps a view of the
/// dictionary's last 32 KiB, not a copy, so the bytes the view belongs to
/// stay alive as long as the encoder.
pub fn Encoder::Encoder(level~ : Int32 = 6, dictionary? : BytesView) -> Encoder {
  let level = level.clamp(min=0, max=9)
  let dictionary = dictionary.map(d => d[(d.length() - 32768).max(0):])
  {
    deflater: match dictionary {
      Some(d) => @flate.Deflater(level~, dictionary=d)
      None => @flate.Deflater(level~)
    },
    dictionary,
  }
}

///|
/// Starts a new stream with the same options: the same level and the same
/// dictionary.
pub fn Encoder::reset(self : Encoder) -> Unit {
  match self.dictionary {
    Some(d) => self.deflater.reset(dictionary=d)
    None => self.deflater.reset()
  }
}

///|
/// Bytes held for the stream, as an upper bound: the deflater's input ring
/// (128 KiB), its match tables (458,754 bytes), the tokens of a block
/// (64 KiB), the output waiting for the caller (32 KiB) and its symbol
/// counts. The deflater allocates the ring and the tables when the encoder
/// is made and does not say how much of the rest a stream uses, so this is
/// the same from the first step to the last: 689,394 bytes, with a
/// dictionary or without. A dictionary is the caller's bytes, kept by
/// reference, and not counted.
pub fn Encoder::memory_usage(_ : Encoder) -> Int32 {
  ENCODER_BYTES
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
  let action : @flate.DeflateAction = match action {
    Continue => Continue
    Flush => SyncFlush
    Finish => Finish
  }
  match self.deflater.step(input, output, action~) {
    Done => Done
    NeedMoreInput => NeedMoreInput
    NeedMoreOutput => NeedMoreOutput
  }
}

///|
/// `step` into a whole `FixedArray`.
pub fn Encoder::step_into(
  self : Encoder,
  input : BytesView,
  output : FixedArray[Byte],
  action~ : EncodeAction,
) -> Status {
  self.step(input, output.mut_view(), action~)
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
pub impl @codec_bytes.Encode for Encoder with fn last_consumed(self) {
  Encoder::last_consumed(self)
}

///|
pub impl @codec_bytes.Encode for Encoder with fn last_produced(self) {
  Encoder::last_produced(self)
}

///|
pub impl @codec_bytes.Encode for Encoder with fn reset(self) {
  Encoder::reset(self)
}

///|
pub impl @codec_bytes.Encode for Encoder with fn memory_usage(self) {
  Encoder::memory_usage(self)
}
