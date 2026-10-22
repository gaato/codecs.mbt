// The streaming encoder.
//
// A zlib stream is the header (`@header.build`: 2 bytes, and DICTID with a
// preset dictionary), the raw DEFLATE data of a `@deflater.Deflater`, the
// encoder that `@deflate.Encoder` holds too, and the Adler-32 of the input,
// big-endian. The header and the trailer wait in
// `framing` until the caller's slices take them; the Adler-32 is updated from
// the input the inner encoder takes.

///|
/// A streaming zlib encoder (RFC 1950). Feed it input in chunks of any size
/// with `step` and collect output in slices of any size; it holds a raw
/// DEFLATE encoder (the one `@deflate.Encoder` holds) and the few bytes of
/// the header and the trailer, never the whole input or output.
pub struct Encoder {
  priv inner : @deflater.Deflater
  // The header, the same for every stream of this encoder.
  priv header : Bytes
  // The header or the trailer bytes not handed out yet: `framing[sent:]`.
  priv mut framing : Bytes
  priv mut sent : Int32
  priv mut trailing : Bool
  priv mut adler : UInt32
  priv mut done : Bool
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
}

///|
/// An encoder at the start of a stream.
///
/// `level` is as for `@deflate.Encoder`: 0 (stored) to 9 (smallest), 6 by
/// default, clamped; the header's FLEVEL says which kind of level it was, as
/// zlib's does.
///
/// `dictionary` is a preset dictionary: the header names it by its Adler-32
/// (`dictionary_id`), and the stream's matches may reach back into its last
/// 32 KiB. A decoder needs the same dictionary. The encoder keeps a view of
/// the dictionary's last 32 KiB, not a copy, so the bytes the view belongs to
/// stay alive as long as the encoder.
pub fn Encoder::Encoder(level~ : Int32 = 6, dictionary? : BytesView) -> Encoder {
  let header = @header.build(level, dictionary.map(dictionary_id))
  {
    inner: @deflater.Deflater::new(level~, dictionary?),
    header,
    framing: header,
    sent: 0,
    trailing: false,
    adler: @adler32.INITIAL,
    done: false,
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Starts a new stream with the same options: the same level and the same
/// dictionary.
pub fn Encoder::reset(self : Encoder) -> Unit {
  self.inner.reset()
  self.framing = self.header
  self.sent = 0
  self.trailing = false
  self.adler = @adler32.INITIAL
  self.done = false
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// Bytes held for the stream: those of the raw DEFLATE encoder (see
/// `@deflate.Encoder::memory_usage`), 542,516 at the default level, with a
/// dictionary or without.
/// A dictionary is the caller's bytes, kept by reference, and not counted;
/// the header and the trailer, at most 6 bytes, are not counted either.
pub fn Encoder::memory_usage(self : Encoder) -> Int32 {
  self.inner.memory_usage()
}

///|
/// Whether the stream has ended and all its output, the trailer included,
/// has been handed out.
pub fn Encoder::is_finished(self : Encoder) -> Bool {
  self.done
}

///|
/// Input bytes the latest `step` took.
pub fn Encoder::last_consumed(self : Encoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote.
pub fn Encoder::last_produced(self : Encoder) -> Int32 {
  self.step_produced
}

///|
/// Compresses from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used. Input that was not taken
/// (when the output is full) must be passed again, with the same action.
///
/// The actions and the statuses are those of `@deflate.Encoder::step`:
/// `Flush` is a sync flush, after which the output so far decodes to the
/// input so far (Discord's `zlib-stream` ends every message with one), and
/// `Finish` ends the stream with the Adler-32 of the input. After `Done`,
/// steps take no input and answer `Done`.
pub fn Encoder::step(
  self : Encoder,
  input : BytesView,
  output : MutArrayView[Byte],
  action~ : EncodeAction,
) -> Status {
  self.step_consumed = 0
  self.step_produced = 0
  if self.done {
    return Done
  }
  let mut consumed = 0
  let mut produced = 0
  for ;; {
    let n = (self.framing.length() - self.sent).min(output.length() - produced)
    for i in 0..<n {
      output[produced + i] = self.framing[self.sent + i]
    }
    self.sent += n
    produced += n
    if self.sent < self.framing.length() {
      return self.finish_step(NeedMoreOutput, consumed, produced)
    }
    if self.trailing {
      // The trailer is out.
      self.done = true
      return self.finish_step(Done, consumed, produced)
    }
    let rest = input[consumed:]
    let status = self.inner.step(rest, output.mut_view(start=produced), action~)
    let taken = self.inner.last_consumed()
    self.adler = @adler32.update_bytes(self.adler, rest[:taken])
    consumed += taken
    produced += self.inner.last_produced()
    match status {
      Done => {
        self.framing = @header.put_be32(self.adler)
        self.sent = 0
        self.trailing = true
      }
      NeedMoreInput =>
        return self.finish_step(NeedMoreInput, consumed, produced)
      NeedMoreOutput =>
        return self.finish_step(NeedMoreOutput, consumed, produced)
    }
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
fn Encoder::finish_step(
  self : Encoder,
  status : Status,
  consumed : Int32,
  produced : Int32,
) -> Status {
  self.step_consumed = consumed
  self.step_produced = produced
  status
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
