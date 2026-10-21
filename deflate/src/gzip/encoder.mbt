// The streaming encoder.
//
// A gzip stream from this encoder is one member: the header
// (`@header.build`), the raw DEFLATE data of a `@deflate.Encoder`, and the
// trailer, the CRC-32 and the length of the input, little-endian. The header
// and the trailer wait in `framing` until the caller's slices take them; the
// CRC-32 and the length are updated from the input the inner encoder takes.

///|
/// Whether an encoder can write this header as it is: the extra field holds
/// at most 65,535 bytes (its length is 2 bytes), and the name and the
/// comment hold no zero byte (a zero ends them). `Encoder` and `compress`
/// abort on a header that is not writable. Whether the extra field is a
/// well-formed sequence of subfields is not checked, by this or by the
/// decoder.
pub fn Header::is_writable(self : Header) -> Bool {
  @header.writable(self.extra, self.name, self.comment)
}

///|
/// The header an encoder writes when given none: no name, comment or extra
/// field, MTIME 0 (unknown), OS 255 (unknown), so that the same input gives
/// the same bytes everywhere, and XFL as zlib sets it for `level`: 4 (the
/// fastest) at levels 0 and 1, 2 (the slowest) at 9, 0 otherwise.
fn default_header(level : Int32) -> Header {
  let level = level.clamp(min=0, max=9)
  {
    text: false,
    mtime: 0,
    xfl: if level == 9 {
      b'\x02'
    } else if level <= 1 {
      b'\x04'
    } else {
      b'\x00'
    },
    os: b'\xff',
    extra: None,
    name: None,
    comment: None,
  }
}

///|
/// A streaming gzip encoder (RFC 1952). Feed it input in chunks of any size
/// with `step` and collect output in slices of any size; it holds a raw
/// DEFLATE encoder (see `@deflate.Encoder`) and the member's header, never
/// the whole input or output. A stream is one member.
pub struct Encoder {
  priv inner : @deflate.Encoder
  // The header's bytes, the same for every stream of this encoder.
  priv header : Bytes
  // The header or the trailer bytes not handed out yet: `framing[sent:]`.
  priv mut framing : Bytes
  priv mut sent : Int32
  priv mut trailing : Bool
  priv mut crc : UInt32
  priv mut size : UInt32
  priv mut done : Bool
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
}

///|
/// An encoder at the start of a stream.
///
/// `level` is as for `@deflate.Encoder`: 0 (stored) to 9 (smallest), 6 by
/// default, clamped.
///
/// `header` is written as it is: FTEXT from `text`, MTIME, XFL and OS, and
/// the extra field, the name and the comment when they are given (never a
/// header CRC). It must be writable (`Header::is_writable`): passing one
/// that is not is the caller's error, and aborts. Without it the encoder
/// writes no name, comment or extra field, MTIME 0 and OS 255 (unknown), so
/// that the same input gives the same bytes on every target and every day,
/// and XFL as zlib does: 4 at levels 0 and 1, 2 at level 9, 0 otherwise.
pub fn Encoder::Encoder(level~ : Int32 = 6, header? : Header) -> Encoder {
  let header = match header {
    Some(h) => {
      guard h.is_writable() else {
        abort(
          "gzip Encoder: the header cannot be written (an extra field over 65,535 bytes, or a zero byte in the name or the comment)",
        )
      }
      h
    }
    None => default_header(level)
  }
  let bytes = @header.build(
    text=header.text,
    mtime=header.mtime,
    xfl=header.xfl,
    os=header.os,
    extra=header.extra,
    name=header.name,
    comment=header.comment,
  )
  {
    inner: @deflate.Encoder(level~),
    header: bytes,
    framing: bytes,
    sent: 0,
    trailing: false,
    crc: @crc32.INITIAL,
    size: 0,
    done: false,
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Starts a new stream with the same options: the same level and the same
/// header.
pub fn Encoder::reset(self : Encoder) -> Unit {
  self.inner.reset()
  self.framing = self.header
  self.sent = 0
  self.trailing = false
  self.crc = @crc32.INITIAL
  self.size = 0
  self.done = false
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// Bytes held for the stream: those of the raw DEFLATE encoder (see
/// `@deflate.Encoder::memory_usage`), 689,394, and the header's bytes, 10
/// and the extra field, the name and the comment. The trailer, 8 bytes, is
/// not counted.
pub fn Encoder::memory_usage(self : Encoder) -> Int32 {
  self.inner.memory_usage() + self.header.length()
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
/// input so far, and `Finish` ends the member with the CRC-32 and the length
/// of the input. After `Done`, steps take no input and answer `Done`.
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
      self.done = true
      return self.finish_step(Done, consumed, produced)
    }
    let rest = input[consumed:]
    let status = self.inner.step(rest, output.mut_view(start=produced), action~)
    let taken = self.inner.last_consumed()
    self.crc = @crc32.update_bytes(self.crc, rest[:taken])
    self.size += taken.reinterpret_as_uint()
    consumed += taken
    produced += self.inner.last_produced()
    match status {
      Done => {
        self.framing = @header.trailer(self.crc, self.size)
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
