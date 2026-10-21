// The streaming decoder.
//
// A gzip stream (RFC 1952) is one or more members. A member is a header (a
// fixed part of 10 bytes, then the optional FEXTRA, FNAME, FCOMMENT and FHCRC
// fields the flags announce), raw DEFLATE, and a trailer of the data's CRC-32
// and length. The fixed part, the extra field's length, the header CRC and
// the trailer gather in `hdr` and are judged by the pure functions of
// `@header`; the variable fields gather in buffers, within
// `max_header_bytes`, or with `keep_header=false` only pass through the header
// CRC. The DEFLATE data goes through a `@deflate.Decoder` that
// stops right after the final block (`EndOfMember`), so the trailer is what it
// leaves of the input; it writes straight into the caller's slice, and the
// CRC-32 and the length are updated from what it wrote.
//
// After a member, under `EndOfInput`, the next bytes must begin another
// member (1f 8b): anything else, zero padding included, is `TrailingData`.

///|
priv enum State {
  /// The fixed part of a header. Before the first member, a stream that does
  /// not begin with the magic number is `Corrupt`.
  Fixed
  ExtraLength
  Extra
  Name
  Comment
  HeaderCrc
  Data
  /// The trailer's CRC32, then its ISIZE.
  TrailerCrc
  TrailerSize
  /// After a member, under `EndOfInput`: the start of another, or the end.
  Between
  Done
}

///|
/// The longest unit gathered in `hdr`: the fixed part of a header.
const HDR_SIZE : Int32 = 10

///|
/// What a member's header says. The extra field, the name and the comment are
/// the bytes the header holds: RFC 1952 writes names and comments in ISO
/// 8859-1, and they are not converted.
pub(all) struct Header {
  /// FTEXT: the data is probably text.
  text : Bool
  /// MTIME: when the original was last modified, in seconds since 1970 UTC;
  /// 0 when unknown.
  mtime : UInt32
  /// XFL: extra flags, for DEFLATE 2 (slowest) or 4 (fastest).
  xfl : Byte
  /// OS: the file system the member was made on (3 Unix, 255 unknown).
  os : Byte
  /// FEXTRA: the extra field's bytes, without their length.
  extra : Bytes?
  /// FNAME: the original file name, without its terminating zero.
  name : Bytes?
  /// FCOMMENT: the comment, without its terminating zero.
  comment : Bytes?
} derive(Eq, @debug.Debug)

///|
pub extend Header with Eq::{equal, not_equal}

///|
pub extend Header with @debug.Debug::{to_repr}

///|
/// A streaming gzip decoder (RFC 1952). Feed it input in chunks of any size
/// with `step` and collect output in slices of any size; it holds a raw
/// DEFLATE decoder (a 32 KiB window and its tables) and the current member's
/// header, never the whole input or output.
pub struct Decoder {
  priv inner : @deflate.Decoder
  priv until : @codec_bytes.Until
  priv keep_header : Bool
  priv max_header_bytes : Int32
  // Fixed-size header and trailer bytes gathered so far.
  priv hdr : FixedArray[Byte]
  priv mut hdr_len : Int32
  // The header being read: its flags, fixed fields, and variable fields as
  // they gather; `held` counts the bytes in the variable fields.
  priv mut fixed : @header.Fixed
  priv mut extra : Buffer?
  priv mut extra_left : Int32
  priv mut name : Buffer?
  priv mut comment : Buffer?
  priv mut held : Int32
  priv mut header_crc : UInt32
  priv mut header : Header?
  // The current step.
  priv mut view : BytesView
  priv mut in_pos : Int32
  priv mut out : MutArrayView[Byte]
  priv mut fixed_out : FixedArray[Byte]?
  priv mut out_pos : Int32
  priv empty_out : FixedArray[Byte]
  // Stream state.
  priv mut state : State
  priv mut members : Int32
  priv mut crc : UInt32
  priv mut size : UInt32
  priv mut failure : @codec.CodecError?
  priv mut step_consumed : Int32
  priv mut step_produced : Int32
}

///|
/// A decoder at the start of a stream.
///
/// `until` says where the stream ends. `EndOfInput`, the default, decodes
/// every member up to the end of the input, as the gzip command does: bytes
/// after a member that begin another (1f 8b) are read as one, and any others,
/// zero padding included, raise `TrailingData`. `EndOfMember` stops right
/// after the first member's trailer and consumes nothing past it, so that
/// `input[last_consumed():]` is what follows, for a caller that decides for
/// itself what may follow a member.
///
/// `keep_header`, true by default, keeps each header's extra field, name and
/// comment for `header()`. `max_header_bytes` bounds the bytes they may hold
/// between them, 65,536 by default; a header that holds more raises
/// `LimitExceeded({ resource: Memory, .. })`. With `keep_header=false` the
/// decoder skips them whatever their size, holding none of their bytes:
/// `header()` then has only the fixed fields, `max_header_bytes` does not
/// apply, and a header CRC is still checked.
pub fn Decoder::Decoder(
  until~ : @codec_bytes.Until = EndOfInput,
  keep_header~ : Bool = true,
  max_header_bytes~ : Int32 = 65536,
) -> Decoder {
  let empty_out = FixedArray::make(0, b'\x00')
  {
    inner: @deflate.Decoder(until=EndOfMember),
    until,
    keep_header,
    max_header_bytes: max_header_bytes.max(0),
    hdr: FixedArray::make(HDR_SIZE, b'\x00'),
    hdr_len: 0,
    fixed: { flags: 0, mtime: 0, xfl: b'\x00', os: b'\x00', },
    extra: None,
    extra_left: 0,
    name: None,
    comment: None,
    held: 0,
    header_crc: @crc32.INITIAL,
    header: None,
    view: b""[:],
    in_pos: 0,
    out: empty_out.mut_view(),
    fixed_out: None,
    out_pos: 0,
    empty_out,
    state: Fixed,
    members: 0,
    crc: @crc32.INITIAL,
    size: 0,
    failure: None,
    step_consumed: 0,
    step_produced: 0,
  }
}

///|
/// Starts a new stream with the same options: the same `until`,
/// `keep_header` and `max_header_bytes`. The header read so far is dropped.
pub fn Decoder::reset(self : Decoder) -> Unit {
  self.release_step()
  self.inner.reset()
  self.hdr_len = 0
  self.drop_header()
  self.state = Fixed
  self.members = 0
  self.failure = None
  self.step_consumed = 0
  self.step_produced = 0
}

///|
/// The header of the current member: the member being decoded, or after the
/// end of the stream the last one. None until the first member's header is
/// complete, and from the moment the next member's header begins until it is
/// complete. With `keep_header=false`, its extra field, name and comment are
/// None whatever the member holds.
pub fn Decoder::header(self : Decoder) -> Header? {
  self.header
}

///|
/// Bytes held for the stream: those of the raw DEFLATE decoder (see
/// `@deflate.Decoder::memory_usage`) and the variable fields of the current
/// header, at most `max_header_bytes`, and none with `keep_header=false`. The
/// fixed-size header and trailer bytes, at most 10, are not counted.
pub fn Decoder::memory_usage(self : Decoder) -> Int32 {
  self.inner.memory_usage() + self.held
}

///|
/// Whether the stream has ended and all its output has been handed out:
/// under `EndOfMember`, after the first member; under `EndOfInput`, at
/// `Done`.
pub fn Decoder::is_finished(self : Decoder) -> Bool {
  self.state is Done
}

///|
/// Input bytes the latest `step` accepted: all of them on `NeedMoreInput`.
/// A step that raised accepted the bytes up to the error; for
/// `TrailingData`, exactly up to the end of the stream, or none if the
/// stream ended before this step's input. A `Corrupt` found inside the
/// DEFLATE data does not count the step's DEFLATE bytes (README, known
/// limits).
pub fn Decoder::last_consumed(self : Decoder) -> Int32 {
  self.step_consumed
}

///|
/// Output bytes the latest `step` wrote, a step that raised included: the
/// output before the error. A `Corrupt` found inside the DEFLATE data does
/// not count the output its step wrote into the slice (README, known
/// limits).
pub fn Decoder::last_produced(self : Decoder) -> Int32 {
  self.step_produced
}

///|
/// Decodes from `input` into `output`; see `last_consumed` and
/// `last_produced` for how much of each it used.
///
/// A stream is one or more members and nothing marks its last one, so pass
/// `end=true` once `input` holds the last bytes and `end=false` before: the
/// stream then ends after the member in progress, and a stream cut short
/// raises `Truncated`. Without `end`, the decoder answers `NeedMoreInput`
/// between members. Under `until=EndOfMember` the stream ends after its first
/// member, whatever `end` says. Output comes before the CRC-32 that covers it
/// is checked, so `ChecksumMismatch` can follow output already handed out.
/// After an error the decoder raises it again, consuming and writing nothing,
/// until `reset`.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_with(input, output, None, end~)
}

///|
/// `step` into a whole `FixedArray`, with bulk copies.
pub fn Decoder::step_into(
  self : Decoder,
  input : BytesView,
  output : FixedArray[Byte],
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_with(input, output.mut_view(), Some(output), end~)
}

///|
fn Decoder::step_with(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_consumed = 0
  self.step_produced = 0
  if self.failure is Some(err) {
    raise err
  }
  self.view = input
  self.in_pos = 0
  self.out = output
  self.fixed_out = fixed_output
  self.out_pos = 0
  let status = self.run(end~) catch {
    NeedInput if end =>
      self.fail(
        CodecError(
          Truncated,
          match self.state {
            Fixed if self.members == 0 && self.hdr_len == 0 =>
              "the input holds no member"
            TrailerCrc | TrailerSize =>
              "the stream ends inside a member's trailer"
            _ => "the stream ends inside a member's header"
          },
        ),
      )
    NeedInput => NeedMoreInput
    Fail(kind, message) => self.fail(CodecError(kind, message))
  }
  self.step_consumed = self.in_pos
  self.step_produced = self.out_pos
  self.release_step()
  status
}

///|
/// Runs the stream's units over the step's input.
fn Decoder::run(self : Decoder, end~ : Bool) -> Status raise Stop {
  for ;; {
    match self.state {
      Fixed => {
        // zlib refuses a bad start before it reads the rest.
        self.fill(@header.START_SIZE)
        checked(
          @header.check_start(Bytes::from_array(self.hdr[0:@header.START_SIZE])),
        )
        self.fill(HDR_SIZE)
        let fixed = checked(
          @header.parse_fixed(Bytes::from_array(self.hdr[0:HDR_SIZE])),
        )
        self.drop_header()
        self.fixed = fixed
        self.header_crc = @crc32.update(@crc32.INITIAL, self.hdr[0:HDR_SIZE])
        self.next_field(ExtraLength)
      }
      ExtraLength => {
        self.fill(2)
        self.header_crc = @crc32.update(self.header_crc, self.hdr[0:2])
        let length = @header.le16(Bytes::from_array(self.hdr[0:2]))
        if self.keep_header {
          self.reserve(length, known=true)
          self.extra = Some(Buffer(size_hint=length))
        }
        self.extra_left = length
        self.state = Extra
      }
      Extra => {
        let take = self.extra_left.min(self.view.length() - self.in_pos)
        self.keep(self.extra, take)
        self.extra_left -= take
        if self.extra_left > 0 {
          raise NeedInput
        }
        self.next_field(Name)
      }
      Name =>
        if self.zero_terminated(self.name) {
          self.next_field(Comment)
        } else {
          raise NeedInput
        }
      Comment =>
        if self.zero_terminated(self.comment) {
          self.next_field(HeaderCrc)
        } else {
          raise NeedInput
        }
      HeaderCrc => {
        self.fill(2)
        checked(
          @header.check_header_crc(
            self.header_crc,
            Bytes::from_array(self.hdr[0:2]),
          ),
          kind=ChecksumMismatch,
        )
        self.next_field(Data)
      }
      Data => {
        let rest = self.view[self.in_pos:]
        let room = self.out.mut_view(start=self.out_pos)
        let status = try {
          match self.fixed_out {
            Some(fixed) if self.out_pos == 0 =>
              self.inner.step_into(rest, fixed, end~)
            _ => self.inner.step(rest, room, end~)
          }
        } catch {
          // The DEFLATE data's error, whatever its kind, after what the inner
          // decoder took and wrote before it.
          CodecError(kind, message) => {
            self.in_pos += self.inner.last_consumed()
            self.out_pos += self.inner.last_produced()
            raise Fail(kind, message)
          }
        }
        let produced = self.inner.last_produced()
        let written = room.exact_view(end=produced)
        self.crc = @crc32.update(self.crc, written)
        self.size += produced.reinterpret_as_uint()
        self.in_pos += self.inner.last_consumed()
        self.out_pos += produced
        match status {
          Done => {
            self.hdr_len = 0
            self.state = TrailerCrc
          }
          NeedMoreInput => return NeedMoreInput
          NeedMoreOutput => return NeedMoreOutput
        }
      }
      TrailerCrc => {
        self.fill(4)
        checked(
          @header.check_crc(self.crc, Bytes::from_array(self.hdr[0:4])),
          kind=ChecksumMismatch,
        )
        self.hdr_len = 0
        self.state = TrailerSize
      }
      TrailerSize => {
        self.fill(4)
        checked(
          @header.check_size(self.size, Bytes::from_array(self.hdr[0:4])),
          kind=ChecksumMismatch,
        )
        self.members += 1
        self.hdr_len = 0
        self.state = if self.until is EndOfMember { Done } else { Between }
      }
      Between => {
        if self.hdr_len == 0 && self.in_pos == self.view.length() {
          if end {
            self.state = Done
            return Done
          }
          raise NeedInput
        }
        // The magic number begins another member; anything else ends the
        // stream with bytes after it.
        let take = (2 - self.hdr_len).min(self.view.length() - self.in_pos)
        let start = Bytes::from_array(
          [
            ..self.hdr[0:self.hdr_len],
            ..self.view[self.in_pos:self.in_pos + take],
          ],
        )
        if !@header.begins_member(start) {
          raise Fail(TrailingData, "data after the last member")
        }
        self.fill(2)
        self.state = Fixed
      }
      Done => {
        if self.until is EndOfInput && self.in_pos < self.view.length() {
          raise Fail(TrailingData, "data after the last member")
        }
        return Done
      }
    }
  }
}

///|
/// Moves on to the first header field from `from` on that the flags announce,
/// or to the data once none is left.
fn Decoder::next_field(self : Decoder, from : State) -> Unit {
  let flags = self.fixed.flags
  self.hdr_len = 0
  self.state = match from {
    ExtraLength if (flags & @header.FEXTRA) != 0 => ExtraLength
    ExtraLength | Name if (flags & @header.FNAME) != 0 => {
      self.name = self.field_buffer()
      Name
    }
    ExtraLength | Name | Comment if (flags & @header.FCOMMENT) != 0 => {
      self.comment = self.field_buffer()
      Comment
    }
    ExtraLength | Name | Comment | HeaderCrc if (flags & @header.FHCRC) != 0 =>
      HeaderCrc
    _ => {
      self.begin_data()
      Data
    }
  }
}

///|
/// The header is complete: it becomes the current one, and the data begins.
fn Decoder::begin_data(self : Decoder) -> Unit {
  let fixed = self.fixed
  self.header = Some({
    text: (fixed.flags & @header.FTEXT) != 0,
    mtime: fixed.mtime,
    xfl: fixed.xfl,
    os: fixed.os,
    extra: self.extra.map(b => b.to_bytes()),
    name: self.name.map(b => b.to_bytes()),
    comment: self.comment.map(b => b.to_bytes()),
  })
  self.extra = None
  self.name = None
  self.comment = None
  self.inner.reset()
  self.crc = @crc32.INITIAL
  self.size = 0
}

///|
/// Forgets the current header and the fields gathered for it.
fn Decoder::drop_header(self : Decoder) -> Unit {
  self.header = None
  self.extra = None
  self.extra_left = 0
  self.name = None
  self.comment = None
  self.held = 0
}

///|
/// A buffer for a name or a comment, or None to skip it.
fn Decoder::field_buffer(self : Decoder) -> Buffer? {
  if self.keep_header {
    Some(Buffer())
  } else {
    None
  }
}

///|
/// Makes room for `n` more bytes of header fields, within `max_header_bytes`.
/// `known` says whether the field declared its size (the extra field), so
/// that the error can say what the header needs.
fn Decoder::reserve(
  self : Decoder,
  n : Int32,
  known~ : Bool,
) -> Unit raise Stop {
  if n > self.max_header_bytes - self.held {
    let limit = self.max_header_bytes.to_uint64()
    raise Fail(
      LimitExceeded({
        resource: Memory,
        needed: if known {
          Some((self.held + n).to_uint64())
        } else {
          None
        },
        limit,
      }),
      "the header's fields exceed \{self.max_header_bytes} bytes",
    )
  }
  self.held += n
}

///|
/// Takes the next `n` input bytes into the field `into`.
fn Decoder::keep(self : Decoder, into : Buffer?, n : Int32) -> Unit {
  let bytes = self.view[self.in_pos:self.in_pos + n]
  if into is Some(buffer) {
    buffer.write_bytesview(bytes)
  }
  self.header_crc = @crc32.update_bytes(self.header_crc, bytes)
  self.in_pos += n
}

///|
/// Takes the input bytes of a zero-terminated field into `into`, or past it
/// when `into` is None, and the zero if it is there: whether the field is
/// complete.
fn Decoder::zero_terminated(self : Decoder, into : Buffer?) -> Bool raise Stop {
  let mut n = 0
  while self.in_pos + n < self.view.length() && self.view[self.in_pos + n] != 0 {
    n += 1
  }
  if into is Some(_) {
    self.reserve(n, known=false)
  }
  self.keep(into, n)
  if self.in_pos == self.view.length() {
    return false
  }
  self.keep(None, 1)
  true
}

///|
/// Gathers fixed-size header or trailer bytes until `hdr` holds `n`.
fn Decoder::fill(self : Decoder, n : Int32) -> Unit raise Stop {
  let take = (n - self.hdr_len).min(self.view.length() - self.in_pos)
  if take > 0 {
    self.hdr.blit_from_bytesview(
      self.hdr_len,
      self.view[self.in_pos:self.in_pos + take],
    )
    self.hdr_len += take
    self.in_pos += take
  }
  if self.hdr_len < n {
    raise NeedInput
  }
}

///|
/// Records a terminal error and raises it, with the step's counts.
fn[T] Decoder::fail(
  self : Decoder,
  err : @codec.CodecError,
) -> T raise @codec.CodecError {
  self.failure = Some(err)
  self.step_consumed = self.in_pos
  self.step_produced = self.out_pos
  self.release_step()
  raise err
}

///|
/// Drops the caller's buffers so a suspended decoder holds neither.
fn Decoder::release_step(self : Decoder) -> Unit {
  self.view = b""[:]
  self.in_pos = 0
  self.out = self.empty_out.mut_view()
  self.fixed_out = None
  self.out_pos = 0
}

///|
pub impl @codec_bytes.Decode for Decoder with fn step(self, input, output, end~) {
  Decoder::step(self, input, output, end~)
}

///|
pub impl @codec_bytes.Decode for Decoder with fn last_consumed(self) {
  Decoder::last_consumed(self)
}

///|
pub impl @codec_bytes.Decode for Decoder with fn last_produced(self) {
  Decoder::last_produced(self)
}

///|
pub impl @codec_bytes.Decode for Decoder with fn reset(self) {
  Decoder::reset(self)
}

///|
pub impl @codec_bytes.Decode for Decoder with fn memory_usage(self) {
  Decoder::memory_usage(self)
}
