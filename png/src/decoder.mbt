// The streaming decoder.
//
// A PNG image (W3C PNG Third Edition) is an 8-byte signature and a sequence
// of chunks, each a 4-byte length, a 4-byte type, the data, and a CRC-32 of
// the type and the data. The decoder reads a chunk in three units: its head
// (length and type) and its CRC gather in `held`, at most 8 bytes, and its
// data passes through, into IHDR's and PLTE's fields, into the zlib decoder
// for IDAT, or only into the CRC for a chunk it skips. Where a chunk may come
// is decided by the pure functions of `@rules` (table 7).
//
// The IDAT chunks' data is one zlib stream, which the decoder inflates into
// the current row's buffer: the filter type byte and the row's bytes. Once the
// row is whole its filter is reversed against the previous row, the two
// buffers swap, and the row waits there for the caller's slice. The previous
// row starts as zeros at each pass. An interlaced image comes out pass by
// pass (Adam7); a pass with no pixels has no rows, not even their filter
// bytes. The zlib decoder writes a whole row with `step_into`, which fills
// an array from its start: when the row buffer is exactly the row (an image
// that is not interlaced, or Adam7's last pass), and the row begins in this
// call. A row of a narrower pass, or one that a previous call began, goes
// through `step` into a view of the buffer. So the decoder holds two rows and the zlib decoder, allocated once
// after IHDR, whatever the image's height.
//
// The answers follow the image contract of `gaato/codec_image`: `Header` at
// IHDR, `Frame` at the first IDAT, `Rows`, and `FrameEnd` at the first chunk
// after the IDAT chunks, once every IDAT's CRC and the zlib stream's
// Adler-32 have been checked. A step that wrote rows stops before anything
// else would be reported; an error found after them is raised by the next
// step.

///|
priv enum State {
  /// The 8-byte signature, checked byte by byte as it comes.
  Signature
  /// IHDR has been reported: the rows' buffers come next.
  Allocate
  /// A chunk's length and type.
  Head
  /// A chunk's head is read and not yet acted on.
  Dispatch
  /// IHDR's 13 bytes.
  HeaderData
  /// PLTE's bytes.
  PaletteData
  /// An fdAT's sequence number.
  Sequence
  /// An IDAT's or an fdAT's frame data, through the zlib decoder.
  ImageData
  /// The bytes of a chunk that is read only through its CRC.
  Skip
  /// The bytes of an ancillary chunk read into fields, or into a block to
  /// report, or both.
  Collect
  /// A reported chunk's block, waiting for room.
  Emit
  /// A chunk's CRC.
  Crc
  /// IEND is checked; under `EndOfInput`, `Done` waits for `end`.
  Ended
}

///|
/// Why a run of the units stopped early, inside the decoder.
priv suberror Stop {
  /// The current unit needs bytes the input does not have yet.
  NeedInput
  /// The image is refused.
  Fail(@codec.ErrorKind, String)
}

///|
/// The 8 bytes every PNG image begins with (5.2).
let signature : FixedArray[Byte] = [
  b'\x89', b'P', b'N', b'G', b'\r', b'\n', b'\x1a', b'\n',
]

///|
/// The longest a chunk's data can be: 2^31 − 1 bytes (5.3).
const MAX_LENGTH : UInt32 = 0x7FFFFFFF

///|
/// The most `max_row_bytes` can be, so that two rows and the zlib decoder fit
/// in what `memory_usage` can count.
const MAX_ROW_BYTES : Int32 = 1_000_000_000

///|
/// The most `max_chunk_bytes` can be, for the same reason.
const MAX_CHUNK_BYTES : Int32 = 100_000_000

///|
/// The color type of an image (table 11): how its pixels' samples are laid
/// out in a row.
pub(all) enum ColorType {
  /// One sample a pixel, a gray level: color type 0.
  Grayscale
  /// Red, green and blue samples: color type 2.
  Truecolor
  /// One index into the palette (`palette`) a pixel: color type 3.
  IndexedColor
  /// A gray level and an alpha sample: color type 4.
  GrayscaleAlpha
  /// Red, green, blue and alpha samples: color type 6.
  TruecolorAlpha
} derive(Eq, @debug.Debug)

///|
/// `ColorType::equal` and `ColorType::not_equal`, the derived comparison.
pub extend ColorType with Eq::{equal, not_equal}

///|
/// `ColorType::to_repr`, the derived debug representation.
pub extend ColorType with @debug.Debug::{to_repr}

///|
/// A streaming PNG decoder. Feed it input in chunks of any size with `step`
/// and collect whole rows in slices of at least `room_needed` bytes; it holds
/// two rows and a zlib decoder (a 32 KiB window and its tables), never the
/// whole image.
pub struct Decoder {
  priv max_row_bytes : Int32
  priv until : @codec_image.Until
  // The IDAT chunks' zlib stream.
  priv inflater : @zlib.Decoder
  // The signature, a chunk's head or its CRC, gathered so far.
  priv held : FixedArray[Byte]
  priv mut held_len : Int32
  // IHDR's bytes and what they say.
  priv ihdr : FixedArray[Byte]
  priv mut ihdr_len : Int32
  priv mut width : Int32
  priv mut height : Int32
  priv mut bit_depth : Int32
  priv mut color_type : Int32
  priv mut interlaced : Bool
  // Bits a pixel, and bytes a whole pixel (at least 1).
  priv mut bits : Int32
  priv mut unit : Int32
  // PLTE's bytes, and the entries the image may use.
  priv plte : FixedArray[Byte]
  priv mut plte_len : Int32
  priv mut entries : Int32
  // The chunks so far, as table 7 sees them, and the current one.
  priv mut state : State
  priv mut position : @rules.Position
  priv mut seen : UInt32
  priv mut chunk : UInt32
  priv mut index : Int32
  priv mut left : Int32
  priv mut crc : UInt32
  priv mut ignoring : Bool
  priv mut ignored : Int32
  // The rows: the previous one, and the current one with its filter type
  // byte first; once whole and unfiltered it is `prev`, waiting (`ready`).
  priv mut prev : FixedArray[Byte]
  priv mut cur : FixedArray[Byte]
  priv mut cur_len : Int32
  priv mut ready : Bool
  priv mut framed : Bool
  priv mut in_frame : Bool
  priv mut pass : Int32
  priv mut pass_rows : Int32
  priv mut pass_bytes : Int32
  priv mut row : Int32
  priv mut rows_done : Bool
  priv mut inflated : Bool
  // The zlib stream's error, raised once the rows before it are out.
  priv mut inflate_error : (@codec.ErrorKind, String)?
  // The current step.
  priv mut pos : Int32
  priv mut produced : Int32
  priv mut consumed : Int32
  priv mut rows_pass : Int32
  priv mut rows_first : Int32
  priv mut rows_count : Int32
  priv mut rows_bytes : Int32
  priv mut failure : @codec.CodecError?
  // The fixed-length ancillary chunks read so far, the current one's bytes,
  // and whether it is read into fields.
  priv fields : Fields
  priv scratch : FixedArray[Byte]
  priv mut scratch_len : Int32
  priv mut field : Bool
  // The ancillary chunk types to report, and the current block.
  priv reported : FixedArray[UInt32]
  priv max_chunk_bytes : Int32
  priv block : Block
  priv mut reporting : Bool
  priv mut metadata_chunk : UInt32
  // APNG: whether to read it, whether the image is one, what acTL says, the
  // fcTL chunks read and the sequence number the next must have, the fcTL
  // whose frame has not begun, and the current frame.
  priv animation : Bool
  priv mut animated : Bool
  priv mut frames : UInt32
  priv mut plays : UInt32
  priv mut controls : UInt32
  priv mut sequence : UInt32
  priv mut pending : Bool
  priv next : Control
  priv control : Control
  priv mut fdat_frame : Bool
  priv mut in_animation : Bool
  // An fcTL that came before acTL, kept for IDAT.
  priv early_control : FixedArray[Byte]
  priv mut early : Bool
  // The caller's array, during a `step_into`.
  priv mut fixed_out : FixedArray[Byte]?
}

///|
/// A decoder at the start of an image.
///
/// `max_row_bytes` bounds the bytes of a row (ceil(width × bits a pixel /
/// 8)): 8,000,000 by default, a million pixels of 16-bit RGBA, and at most
/// 1,000,000,000. The decoder holds two rows; an image whose rows are longer
/// raises `LimitExceeded(Memory)` with a row's bytes, at the step after
/// `Header`, before anything is allocated for it. Its height is not bounded,
/// since rows are handed out as they come.
///
/// `report` names the ancillary chunk types to hand out, each as one block
/// of `Metadata` once its CRC has passed (see `metadata_type`); by default
/// none. A name that is not an ancillary chunk type matches nothing. Their
/// data is held until then, so a reported chunk of more than
/// `max_chunk_bytes` bytes (1 MiB by default, at most 100,000,000) raises
/// `LimitExceeded(Memory)` with its length, and so does one that inflates to
/// more. iCCP's profile, zTXt's text and iTXt's compressed text come out
/// inflated, through a second zlib decoder, which the decoder holds only
/// when one of them is asked for.
///
/// `animation` says whether to read APNG's chunks (acTL, fcTL, fdAT): each
/// frame of an animation is then a `Frame` with its rows. With
/// `animation=false` they are skipped as unknown chunks, and an animated
/// image gives its default image only.
///
/// `until` says where the image ends. `EndOfInput`, the default, decodes the
/// image up to the end of the input, and bytes after IEND raise
/// `TrailingData`. `EndOfMember` stops right after IEND and consumes nothing
/// past it, so that `input[last_consumed():]` is what follows.
pub fn Decoder::Decoder(
  max_row_bytes~ : Int32 = 8_000_000,
  report~ : Array[String] = [],
  max_chunk_bytes~ : Int32 = 1 << 20,
  animation~ : Bool = true,
  until~ : @codec_image.Until = EndOfInput,
) -> Decoder {
  let none = FixedArray::make(0, b'\x00')
  let max_chunk_bytes = max_chunk_bytes.max(0).min(MAX_CHUNK_BYTES)
  let reported = FixedArray::from_array(
    report.filter_map(name => {
      guard name.length() == 4 && name.iter().all(c => c.to_int() < 128) else {
        return None
      }
      let t = @rules.chunk_type(
        name[0].to_byte(),
        name[1].to_byte(),
        name[2].to_byte(),
        name[3].to_byte(),
      )
      if @rules.is_valid_type(t) && !@rules.is_critical(t) {
        Some(t)
      } else {
        None
      }
    }),
  )
  {
    max_row_bytes: max_row_bytes.max(0).min(MAX_ROW_BYTES),
    until,
    inflater: @zlib.Decoder::Decoder(until=EndOfMember),
    held: FixedArray::make(8, b'\x00'),
    held_len: 0,
    ihdr: FixedArray::make(13, b'\x00'),
    ihdr_len: 0,
    width: 0,
    height: 0,
    bit_depth: 0,
    color_type: 0,
    interlaced: false,
    bits: 0,
    unit: 1,
    plte: FixedArray::make(768, b'\x00'),
    plte_len: 0,
    entries: 0,
    state: Signature,
    position: BeforeHeader,
    seen: 0,
    chunk: 0,
    index: -1,
    left: 0,
    crc: 0,
    ignoring: false,
    ignored: 0,
    prev: none,
    cur: none,
    cur_len: 0,
    ready: false,
    framed: false,
    in_frame: false,
    pass: 0,
    pass_rows: 0,
    pass_bytes: 0,
    row: 0,
    rows_done: false,
    inflated: false,
    inflate_error: None,
    pos: 0,
    produced: 0,
    consumed: 0,
    rows_pass: 0,
    rows_first: 0,
    rows_count: 0,
    rows_bytes: 0,
    failure: None,
    fixed_out: None,
    fields: Fields::new(),
    scratch: FixedArray::make(FIELD_BYTES, b'\x00'),
    scratch_len: 0,
    field: false,
    reported,
    max_chunk_bytes,
    block: Block::new(
      max_chunk_bytes,
      reported
      .iter()
      .any(t => @rules.known(t) is (@rules.ICCP | @rules.ZTXT | @rules.ITXT)),
    ),
    reporting: false,
    metadata_chunk: 0,
    animation,
    animated: false,
    frames: 0,
    plays: 0,
    controls: 0,
    sequence: 0,
    pending: false,
    next: Control::new(),
    control: Control::new(),
    fdat_frame: false,
    in_animation: false,
    early_control: FixedArray::make(26, b'\x00'),
    early: false,
  }
}

///|
/// Starts a new image with the same options. The rows' buffers are dropped.
pub fn Decoder::reset(self : Decoder) -> Unit {
  self.inflater.reset()
  self.held_len = 0
  self.ihdr_len = 0
  self.width = 0
  self.height = 0
  self.bit_depth = 0
  self.color_type = 0
  self.interlaced = false
  self.bits = 0
  self.unit = 1
  self.plte_len = 0
  self.entries = 0
  self.state = Signature
  self.position = BeforeHeader
  self.seen = 0
  self.chunk = 0
  self.index = -1
  self.left = 0
  self.crc = 0
  self.ignoring = false
  self.ignored = 0
  self.prev = FixedArray::make(0, b'\x00')
  self.cur = self.prev
  self.cur_len = 0
  self.ready = false
  self.framed = false
  self.in_frame = false
  self.pass = 0
  self.pass_rows = 0
  self.pass_bytes = 0
  self.row = 0
  self.rows_done = false
  self.inflated = false
  self.inflate_error = None
  self.produced = 0
  self.consumed = 0
  self.rows_count = 0
  self.failure = None
  self.fields.reset()
  self.scratch_len = 0
  self.field = false
  self.block.release()
  self.reporting = false
  self.animated = false
  self.frames = 0
  self.plays = 0
  self.controls = 0
  self.sequence = 0
  self.pending = false
  self.fdat_frame = false
  self.in_animation = false
  self.early = false
}

///|
/// Bytes held for the image: the zlib decoder's 46,592 (see
/// `@zlib.Decoder::memory_usage`), the 768 of the palette, and from the step
/// after `Header` two rows of 1 + `row_bytes` bytes each, for the image's
/// full width. With chunks to report, the block of the one being read, and
/// the second zlib decoder's 46,592 when iCCP, zTXt or iTXt is reported. The
/// signature, chunk heads and CRCs (8 bytes at a time), IHDR's 13 bytes and
/// the 256 into which a fixed-length ancillary chunk is read are not
/// counted.
pub fn Decoder::memory_usage(self : Decoder) -> Int32 {
  self.inflater.memory_usage() +
  self.plte.length() +
  self.prev.length() +
  self.cur.length() +
  self.block.memory()
}

///|
/// Input bytes the latest `step` consumed: all of them on `NeedMoreInput`.
/// A step that raised reports the bytes up to the error, and zero when an
/// earlier step found it; for `TrailingData`, exactly up to the end of the
/// image.
pub fn Decoder::last_consumed(self : Decoder) -> Int32 {
  self.consumed
}

///|
/// Output bytes the latest `step` wrote: those of its rows after `Rows`, and
/// zero after any other answer, an error included.
pub fn Decoder::last_produced(self : Decoder) -> Int32 {
  self.produced
}

///|
/// The smallest output slice the next step can write into: a reported
/// chunk's block when one waits, the bytes of the current pass's rows while
/// the frame has rows to come, else zero.
pub fn Decoder::room_needed(self : Decoder) -> Int32 {
  if self.state is Emit {
    self.block.len
  } else if self.in_frame && !self.rows_done {
    self.pass_bytes
  } else {
    0
  }
}

///|
/// The image's width, in pixels. Valid from `Header` until `reset`.
pub fn Decoder::width(self : Decoder) -> Int32 {
  self.width
}

///|
/// The image's height, in pixels. Valid from `Header` until `reset`.
pub fn Decoder::height(self : Decoder) -> Int32 {
  self.height
}

///|
/// Bits a sample, or a palette index: 1, 2, 4, 8 or 16 (table 12). Valid
/// from `Header` until `reset`.
pub fn Decoder::bit_depth(self : Decoder) -> Int32 {
  self.bit_depth
}

///|
/// How the samples of a pixel are laid out. Valid from `Header` until
/// `reset`.
pub fn Decoder::color_type(self : Decoder) -> ColorType {
  match self.color_type {
    0 => Grayscale
    2 => Truecolor
    3 => IndexedColor
    4 => GrayscaleAlpha
    _ => TruecolorAlpha
  }
}

///|
/// Whether the image is interlaced with Adam7: its rows then come in seven
/// passes, each a lattice of the image (`pass_x`, `pass_dx`, ...), and a
/// pass with no pixels is skipped. Valid from `Header` until `reset`.
pub fn Decoder::interlaced(self : Decoder) -> Bool {
  self.interlaced
}

///|
/// The palette: red, green and blue, one byte each, for every entry the
/// image can use. An indexed-color image has one (PLTE is required); entries
/// beyond what its bit depth can index are dropped, as libpng drops them. A
/// truecolor image may have one as a suggestion; other images have none.
/// Valid from `Frame` until `reset`. Rows hold indices as they are, so an
/// index past the palette is the caller's to handle (the specification
/// shows it as opaque black).
pub fn Decoder::palette(self : Decoder) -> ArrayView[Byte] {
  self.plte[:self.entries * 3]
}

///|
/// Ancillary chunks left out so far: those out of the place table 7 gives
/// them, second copies of chunks that may come once, those whose CRC does
/// not match, and a PLTE that a grayscale image does not use or that is out
/// of place in a truecolor one. Unknown ancillary chunks are skipped and not
/// counted.
pub fn Decoder::ignored_chunks(self : Decoder) -> Int32 {
  self.ignored
}

///|
/// The left edge of the current frame: its fcTL's x offset, and 0 for a
/// default image. Valid from `Frame` until the next `Frame` or `Done`.
pub fn Decoder::frame_x(self : Decoder) -> Int32 {
  self.control.x
}

///|
/// The top edge of the current frame. Valid from `Frame` until the next
/// `Frame` or `Done`.
pub fn Decoder::frame_y(self : Decoder) -> Int32 {
  self.control.y
}

///|
/// The current frame's width: the image's for a default image. Valid from
/// `Frame` until the next `Frame` or `Done`.
pub fn Decoder::frame_width(self : Decoder) -> Int32 {
  self.control.width
}

///|
/// The current frame's height. Valid from `Frame` until the next `Frame` or
/// `Done`.
pub fn Decoder::frame_height(self : Decoder) -> Int32 {
  self.control.height
}

///|
/// The pass the last `Rows` belong to: 0 to 6 for Adam7, 0 for an image that
/// is not interlaced. Valid after `Rows`, until the next step.
pub fn Decoder::pass(self : Decoder) -> Int32 {
  self.rows_pass
}

///|
/// The column of the image where the last `Rows`' pass begins. Valid after
/// `Rows`, until the next step.
pub fn Decoder::pass_x(self : Decoder) -> Int32 {
  @rules.pass_x(self.interlaced, self.rows_pass)
}

///|
/// The row of the image where the last `Rows`' pass begins. Valid after
/// `Rows`, until the next step.
pub fn Decoder::pass_y(self : Decoder) -> Int32 {
  @rules.pass_y(self.interlaced, self.rows_pass)
}

///|
/// The distance between the columns of the last `Rows`' pass. Valid after
/// `Rows`, until the next step.
pub fn Decoder::pass_dx(self : Decoder) -> Int32 {
  @rules.pass_dx(self.interlaced, self.rows_pass)
}

///|
/// The distance between the rows of the last `Rows`' pass. Valid after
/// `Rows`, until the next step.
pub fn Decoder::pass_dy(self : Decoder) -> Int32 {
  @rules.pass_dy(self.interlaced, self.rows_pass)
}

///|
/// The row of its pass the last `Rows` begin at. Valid after `Rows`, until
/// the next step.
pub fn Decoder::rows_first(self : Decoder) -> Int32 {
  self.rows_first
}

///|
/// How many rows the last `Rows` wrote. Valid after `Rows`, until the next
/// step.
pub fn Decoder::rows_count(self : Decoder) -> Int32 {
  self.rows_count
}

///|
/// The bytes of each row the last `Rows` wrote: the pass's pixels, packed as
/// the image's color type and bit depth say, without the filter type byte.
/// Valid after `Rows`, until the next step.
pub fn Decoder::row_bytes(self : Decoder) -> Int32 {
  self.rows_bytes
}

///|
/// Decodes from `input` into `output`, and says why it stopped; see
/// `last_consumed` and `last_produced` for how much of each it used.
///
/// Pass `end=true` once `input` holds the last bytes and `end=false` before:
/// an image cut short then raises `Truncated`. A step that writes, writes
/// whole rows of one pass and answers `Rows`; it stops at `Header`, `Frame`
/// and `FrameEnd` without writing. `NeedMoreOutput` means `output` is
/// shorter than the next row, `room_needed` bytes. Rows come out before the
/// CRCs and the Adler-32 that cover them are checked, so `ChecksumMismatch`
/// can follow rows already handed out; `FrameEnd` comes once they have
/// passed. A step that raises writes nothing: the rows before the error came
/// out in the steps before it. After an error the decoder raises it again,
/// consuming and writing nothing, until `reset`.
pub fn Decoder::step(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_with(input, output, None, end~)
}

///|
/// `step` into a whole `FixedArray`, with bulk copies of the rows.
pub fn Decoder::step_into(
  self : Decoder,
  input : BytesView,
  output : FixedArray[Byte],
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.step_with(input, output.mut_view(), Some(output), end~)
}

///|
/// A step into `output`, which is the whole of `fixed_output` when given.
fn Decoder::step_with(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  fixed_output : FixedArray[Byte]?,
  end~ : Bool,
) -> Status raise @codec.CodecError {
  self.fixed_out = fixed_output
  defer {
    self.fixed_out = None
  }
  self.consumed = 0
  self.produced = 0
  self.rows_count = 0
  if self.failure is Some(err) {
    raise err
  }
  self.pos = 0
  let status = self.run(input, output, end~) catch {
    NeedInput if self.produced > 0 => Rows
    NeedInput if end =>
      self.fail(
        Truncated,
        if self.state is Signature && self.held_len == 0 {
          "the input holds no image"
        } else {
          "the input ends inside the image"
        },
      )
    NeedInput => NeedMoreInput
    Fail(kind, message) if self.produced > 0 => {
      self.failure = Some(CodecError(kind, message))
      Rows
    }
    Fail(kind, message) => self.fail(kind, message)
  }
  self.consumed = self.pos
  status
}

///|
/// Records a terminal error and raises it, from a step that wrote nothing.
fn[T] Decoder::fail(
  self : Decoder,
  kind : @codec.ErrorKind,
  message : String,
) -> T raise @codec.CodecError {
  let err = @codec.CodecError(kind, message)
  self.failure = Some(err)
  self.consumed = self.pos
  raise err
}

///|
/// Runs the image's units over the step's input.
fn Decoder::run(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
  end~ : Bool,
) -> Status raise Stop {
  for ;; {
    match self.state {
      Signature => {
        while self.held_len < 8 && self.pos < input.length() {
          if input[self.pos] != signature[self.held_len] {
            raise Fail(Corrupt, "the input does not begin with PNG's signature")
          }
          self.held_len += 1
          self.pos += 1
        }
        if self.held_len < 8 {
          raise NeedInput
        }
        self.held_len = 0
        self.state = Head
      }
      Allocate => {
        let bytes = @rules.row_bytes(
          self.width.reinterpret_as_uint(),
          self.bits,
          self.max_row_bytes,
        ) catch {
          CodecError(kind, message) => raise Fail(kind, message)
        }
        self.prev = FixedArray::make(1 + bytes, b'\x00')
        self.cur = FixedArray::make(1 + bytes, b'\x00')
        self.state = Head
      }
      Head => {
        self.gather(input, 8)
        let h = self.held
        let length = @rules.chunk_type(h[0], h[1], h[2], h[3])
        if length > MAX_LENGTH {
          raise Fail(Corrupt, "a chunk's length of \{length} bytes")
        }
        self.left = length.reinterpret_as_int()
        self.chunk = @rules.chunk_type(h[4], h[5], h[6], h[7])
        self.crc = @crc32.update(@crc32.INITIAL, h[4:8])
        self.held_len = 0
        self.state = Dispatch
      }
      Dispatch => {
        let status = self.dispatch()
        if status is Some(status) {
          return status
        }
      }
      HeaderData => {
        self.ihdr_len = self.take(input, self.ihdr, self.ihdr_len)
        if self.left > 0 {
          raise NeedInput
        }
        self.state = Crc
      }
      PaletteData => {
        self.plte_len = self.take(input, self.plte, self.plte_len)
        if self.left > 0 {
          raise NeedInput
        }
        self.state = Crc
      }
      Sequence => {
        self.gather(input, 4)
        let h = self.held
        self.crc = @crc32.update(self.crc, h[0:4])
        self.held_len = 0
        self.left -= 4
        self.check_sequence(@rules.chunk_type(h[0], h[1], h[2], h[3]))
        self.state = ImageData
        if !self.in_frame {
          self.control.copy(self.next)
          self.pending = false
          self.in_animation = true
          self.begin_frame(fdat=true)
          return Frame
        }
      }
      ImageData => {
        let status = self.image_data(input, output)
        if status is Some(status) {
          return status
        }
      }
      Skip => {
        let n = self.left.min(input.length() - self.pos)
        self.crc = @crc32.update_bytes(self.crc, input[self.pos:self.pos + n])
        self.pos += n
        self.left -= n
        if self.left > 0 {
          raise NeedInput
        }
        self.state = Crc
      }
      Collect => {
        let n = self.left.min(input.length() - self.pos)
        let data = input[self.pos:self.pos + n]
        self.crc = @crc32.update_bytes(self.crc, data)
        if self.field {
          self.scratch.blit_from_bytesview(self.scratch_len, data)
          self.scratch_len += n
        }
        if self.reporting {
          self.block.feed(data)
        }
        self.pos += n
        self.left -= n
        if self.left > 0 {
          raise NeedInput
        }
        self.state = Crc
      }
      Emit => {
        let n = self.block.len
        if n > output.length() - self.produced {
          return if self.produced > 0 { Rows } else { NeedMoreOutput }
        }
        // SAFETY: `n <= output.length()` was checked above, and the block
        // holds `n` bytes.
        match self.fixed_out {
          Some(out) => blit(out, 0, self.block.data, 0, n)
          None =>
            for i in 0..<n {
              output.unsafe_set(i, self.block.data.unsafe_get(i))
            }
        }
        self.produced = n
        self.metadata_chunk = self.block.chunk
        self.block.release()
        self.state = Head
        return Metadata
      }
      Crc => {
        self.gather(input, 4)
        let h = self.held
        let stored = @rules.chunk_type(h[0], h[1], h[2], h[3])
        self.held_len = 0
        let status = self.close_chunk(stored == self.crc)
        if status is Some(status) {
          return status
        }
      }
      Ended =>
        return if self.until is EndOfMember {
          Done
        } else if self.pos < input.length() {
          raise Fail(TrailingData, "data after IEND")
        } else if end {
          Done
        } else {
          NeedMoreInput
        }
    }
  }
}

///|
/// Gathers bytes into `held` until it holds `n`.
fn Decoder::gather(
  self : Decoder,
  input : BytesView,
  n : Int32,
) -> Unit raise Stop {
  let take = (n - self.held_len).min(input.length() - self.pos)
  if take > 0 {
    self.held.blit_from_bytesview(
      self.held_len,
      input[self.pos:self.pos + take],
    )
    self.held_len += take
    self.pos += take
  }
  if self.held_len < n {
    raise NeedInput
  }
}

///|
/// Copies the chunk's data into `into` from `at`, through the CRC, and
/// returns how far `into` is filled.
fn Decoder::take(
  self : Decoder,
  input : BytesView,
  into : FixedArray[Byte],
  at : Int32,
) -> Int32 {
  let n = self.left.min(input.length() - self.pos)
  let data = input[self.pos:self.pos + n]
  into.blit_from_bytesview(at, data)
  self.crc = @crc32.update_bytes(self.crc, data)
  self.pos += n
  self.left -= n
  at + n
}

///|
/// Acts on a chunk whose head is read. Ends the frame first when the IDAT
/// chunks are over; a step that wrote rows stops before that, and the next
/// one comes back here.
fn Decoder::dispatch(self : Decoder) -> Status? raise Stop {
  let t = self.chunk
  if !@rules.is_valid_type(t) {
    raise Fail(Corrupt, "a chunk type that is not four letters")
  }
  let mut index = @rules.known(t)
  let apng = index is (@rules.ACTL | @rules.FCTL | @rules.FDAT)
  // Outside an APNG, its chunks are unknown ones; but an fcTL before IDAT
  // may come before acTL, and is kept until IDAT says which it was.
  let read_apng = index == @rules.ACTL ||
    self.animated ||
    (index == @rules.FCTL && !self.framed)
  if apng && !(self.animation && read_apng) {
    index = -1
  }
  // A frame of IDAT ends at the first other chunk; one of fdAT at the next
  // fcTL or IEND, since other chunks may come between its fdAT chunks.
  let ends = if self.fdat_frame {
    index is (@rules.FCTL | @rules.IEND)
  } else {
    index != @rules.IDAT
  }
  if self.in_frame && ends {
    if self.produced > 0 {
      return Some(Rows)
    }
    if !self.rows_done {
      raise Fail(Corrupt, "the image data ends before the image's last row")
    }
    if !self.inflated {
      raise Fail(Corrupt, "the zlib stream does not end in the IDAT chunks")
    }
    self.in_frame = false
    return Some(FrameEnd)
  }
  let verdict = if index == -1 && apng && !(self.position is BeforeHeader) {
    @rules.Verdict::Accept
  } else {
    @rules.place(self.position, t, self.seen, self.color_type)
  }
  if verdict is Refuse(kind, message) {
    raise Fail(kind, message)
  }
  // In an APNG, a second fcTL before IDAT or an fdAT before it is out of
  // the order of its sequence.
  if index is (@rules.FCTL | @rules.FDAT) && verdict is Ignore && self.animated {
    raise Fail(Corrupt, "\{@rules.type_name(t)} out of order")
  }
  // Nor can an APNG have a second acTL; one after IDAT, before which the
  // image was not animated, is left out like any misplaced chunk.
  if index == @rules.ACTL && verdict is Ignore && self.animated {
    raise Fail(Corrupt, "a second acTL")
  }
  self.position = @rules.after(self.position, t, verdict)
  self.index = index
  self.ignoring = verdict is Ignore
  if verdict is Accept && index >= 0 {
    self.seen = self.seen | (1U << index)
  }
  self.state = Skip
  match index {
    @rules.IHDR => {
      if self.left != 13 {
        raise Fail(Corrupt, "an IHDR of \{self.left} bytes")
      }
      self.state = HeaderData
    }
    @rules.PLTE if verdict is Accept => {
      let fits = self.left > 0 && self.left <= 768 && self.left % 3 == 0
      if fits {
        self.plte_len = 0
        self.state = PaletteData
      } else if self.color_type == 3 {
        raise Fail(Corrupt, "a PLTE of \{self.left} bytes")
      } else {
        self.ignoring = true
      }
    }
    @rules.IDAT => {
      self.state = ImageData
      if !self.framed {
        // The default image: the frame of the fcTL before it, if any, and
        // if acTL came before it too.
        if self.animated && self.early {
          self.early_control.blit_to(self.scratch, len=26)
          self.read_fctl()
        }
        self.framed = true
        self.in_animation = self.pending
        if self.pending {
          self.control.copy(self.next)
          self.pending = false
        } else {
          self.control.whole(self.width, self.height)
        }
        self.begin_frame(fdat=false)
        return Some(Frame)
      }
    }
    @rules.FDAT => {
      if !self.in_frame && !self.pending {
        raise Fail(Corrupt, "fdAT without an fcTL before it")
      }
      if self.left < 4 {
        raise Fail(Corrupt, "an fdAT of \{self.left} bytes")
      }
      self.state = Sequence
    }
    @rules.FCTL if verdict is Accept => {
      if self.pending {
        raise Fail(Corrupt, "an fcTL whose frame has no data")
      }
      if self.left != 26 {
        raise Fail(Corrupt, "an fcTL of \{self.left} bytes")
      }
      self.begin_ancillary(t, index)
    }
    @rules.IEND => {
      if self.animated && self.pending {
        raise Fail(Corrupt, "an fcTL whose frame has no data")
      }
      if self.animated && self.controls != self.frames {
        raise Fail(
          Corrupt,
          "acTL says \{self.frames} frames, and there are \{self.controls}",
        )
      }
      self.ignoring = self.left > 0
    }
    _ => if !self.ignoring { self.begin_ancillary(t, index) }
  }
  None
}

///|
/// Begins an ancillary chunk that table 7 places where it is: read into
/// fields, reported, or both, or only skipped through its CRC. A chunk to
/// read into fields that is longer than any of their kind is left out.
fn Decoder::begin_ancillary(
  self : Decoder,
  t : UInt32,
  index : Int32,
) -> Unit raise Stop {
  let fields = is_field(index) || index is (@rules.ACTL | @rules.FCTL)
  self.field = fields && self.left <= FIELD_BYTES
  if fields && !self.field {
    self.ignoring = true
    return
  }
  self.reporting = self.reported.contains(t)
  if self.reporting && self.left > self.max_chunk_bytes {
    raise Fail(
      LimitExceeded({
        resource: Memory,
        needed: Some(self.left.to_uint64()),
        limit: self.max_chunk_bytes.to_uint64(),
      }),
      "a \{@rules.type_name(t)} of \{self.left} bytes, over max_chunk_bytes",
    )
  }
  if self.reporting {
    self.block.start(t, index, self.left)
  }
  if self.field || self.reporting {
    self.scratch_len = 0
    self.state = Collect
  }
}

///|
/// Acts on a chunk once its CRC is read: `checked` says whether it matched.
/// A critical chunk's mismatch is refused, an ancillary one's leaves the
/// chunk out; PLTE is ancillary in an image that is not indexed-color.
fn Decoder::close_chunk(self : Decoder, checked : Bool) -> Status? raise Stop {
  // In an APNG, fcTL and fdAT are as needed as IDAT.
  let critical = (
      self.index >= 0 &&
      self.index <= @rules.IEND &&
      (self.index != @rules.PLTE || self.color_type == 3)
    ) ||
    (self.animated && self.index is (@rules.FCTL | @rules.FDAT))
  if !checked && critical {
    raise Fail(
      ChecksumMismatch,
      "the CRC of \{@rules.type_name(self.chunk)} does not match",
    )
  }
  let mut used = checked && !self.ignoring
  if used && self.field {
    used = match self.index {
      @rules.ACTL => self.read_actl()
      @rules.FCTL if self.animated => {
        self.read_fctl()
        true
      }
      @rules.FCTL => {
        // Before acTL: kept for IDAT.
        self.scratch.blit_to(self.early_control, len=26)
        self.early = true
        true
      }
      _ =>
        self.fields.read(
          self.index,
          self.scratch,
          self.scratch_len,
          self.color_type,
          self.bit_depth,
          self.entries,
        )
    }
  }
  if used && self.reporting {
    used = self.block.finish()
  }
  if !used {
    self.ignored += 1
    // A later valid copy of a chunk left out may still be read.
    if self.index > @rules.IEND {
      self.seen = self.seen & (1U << self.index).lnot()
    }
  }
  self.field = false
  self.state = Head
  if self.reporting {
    self.reporting = false
    if used {
      self.state = Emit
      return None
    }
    self.block.release()
  }
  match self.index {
    @rules.IHDR => {
      self.read_header()
      self.state = Allocate
      return Some(Header)
    }
    @rules.PLTE if used => {
      let most = if self.color_type == 3 { 1 << self.bit_depth } else { 256 }
      self.entries = (self.plte_len / 3).min(most)
    }
    @rules.IEND => self.state = Ended
    _ => ()
  }
  None
}

///|
/// Reads IHDR's fields, refusing those that describe no image.
fn Decoder::read_header(self : Decoder) -> Unit raise Stop {
  let h = self.ihdr
  let width = @rules.chunk_type(h[0], h[1], h[2], h[3])
  let height = @rules.chunk_type(h[4], h[5], h[6], h[7])
  let bit_depth = h[8].to_int()
  let color_type = h[9].to_int()
  if @rules.check_header(
      width,
      height,
      bit_depth,
      color_type,
      h[10].to_int(),
      h[11].to_int(),
      h[12].to_int(),
    )
    is Some(message) {
    raise Fail(Corrupt, "IHDR: \{message}")
  }
  self.width = width.reinterpret_as_int()
  self.height = height.reinterpret_as_int()
  self.bit_depth = bit_depth
  self.color_type = color_type
  self.interlaced = h[12] == b'\x01'
  self.bits = @rules.channels(color_type) * bit_depth
  self.unit = (self.bits / 8).max(1)
}

///|
/// Begins a frame's data: its zlib stream from the start, its rows from the
/// first pass that has pixels. The only place the zlib decoder is reset
/// within an image, so that no frame inherits another's stream.
fn Decoder::begin_frame(self : Decoder, fdat~ : Bool) -> Unit {
  self.inflater.reset()
  self.fdat_frame = fdat
  self.in_frame = true
  self.rows_done = false
  self.inflated = false
  self.inflate_error = None
  self.ready = false
  self.start_pass(0)
}

///|
/// Reads acTL: an animation of at least one frame, and how many times to
/// play it. One of no frames is left out, and the image is not animated.
fn Decoder::read_actl(self : Decoder) -> Bool {
  guard self.scratch_len == 8 else { return false }
  let frames = u32(self.scratch, 0)
  guard frames > 0 && frames <= 0x7FFFFFFF else { return false }
  self.frames = frames
  self.plays = u32(self.scratch, 4)
  self.animated = self.animation
  true
}

///|
/// Reads an fcTL, whose sequence number must be the next: the frame it
/// describes waits for its first data chunk.
fn Decoder::read_fctl(self : Decoder) -> Unit raise Stop {
  self.check_sequence(u32(self.scratch, 0))
  self.next.read(
    self.scratch,
    self.width,
    self.height,
    default_image=!self.framed,
    first=self.controls == 0,
  )
  self.controls += 1
  self.pending = true
}

///|
/// Checks a sequence number of fcTL or fdAT against the next one expected.
fn Decoder::check_sequence(self : Decoder, number : UInt32) -> Unit raise Stop {
  if number != self.sequence {
    raise Fail(
      Corrupt,
      "sequence number \{number} where \{self.sequence} was due",
    )
  }
  self.sequence += 1
}

///|
/// Starts the first pass from `pass` on that has pixels, with a previous row
/// of zeros, or ends the rows when none is left.
fn Decoder::start_pass(self : Decoder, pass : Int32) -> Unit {
  for p in pass..<@rules.passes(self.interlaced) {
    let columns = @rules.pass_columns(self.interlaced, p, self.control.width)
    let rows = @rules.pass_rows(self.interlaced, p, self.control.height)
    if columns > 0 && rows > 0 {
      self.pass = p
      self.pass_rows = rows
      self.pass_bytes = @rules.pass_row_bytes(columns, self.bits)
      self.row = 0
      self.cur_len = 0
      self.prev.fill(b'\x00', end=1 + self.pass_bytes)
      return
    }
  }
  self.rows_done = true
}

///|
/// Inflates an IDAT's data into rows and hands them out, until the input,
/// the chunk or the room runs out, or the pass ends.
fn Decoder::image_data(
  self : Decoder,
  input : BytesView,
  output : MutArrayView[Byte],
) -> Status? raise Stop {
  for ;; {
    if self.ready {
      if !self.write_row(output) {
        return Some(if self.produced > 0 { Rows } else { NeedMoreOutput })
      }
      if self.rows_done || self.pass != self.rows_pass {
        return Some(Rows)
      }
      continue
    }
    let n = self.left.min(input.length() - self.pos)
    let data = input[self.pos:self.pos + n]
    if self.inflate_error is Some((kind, message)) {
      raise Fail(kind, message)
    }
    if self.inflated {
      if !self.rows_done {
        raise Fail(Corrupt, "the zlib stream ends before the image's last row")
      }
      // Bytes after the zlib stream are dropped (11.2.3), through the CRC.
      self.crc = @crc32.update_bytes(self.crc, data)
      self.pos += n
      self.left -= n
    } else {
      let full = 1 + self.pass_bytes
      let inflater = self.inflater
      let status = try {
        if self.rows_done || (self.cur_len == 0 && self.cur.length() == full) {
          // A whole row, or once the rows are done, data past them, which
          // is inflated only to reach the Adler-32 and then dropped.
          inflater.step_into(data, self.cur, end=false)
        } else {
          inflater.step(
            data,
            self.cur.mut_view(start=self.cur_len, end=full),
            end=false,
          )
        }
      } catch {
        CodecError(kind, message) => {
          // What the zlib decoder wrote before its error may complete a
          // row, which comes out first.
          self.consume(data, inflater.last_consumed())
          self.inflate_error = Some((kind, "IDAT: \{message}"))
          if !self.rows_done {
            self.cur_len += inflater.last_produced()
            if self.cur_len == full {
              self.finish_row()
            }
          }
          continue
        }
      }
      let used = inflater.last_consumed()
      let made = inflater.last_produced()
      self.consume(data, used)
      if status is Done {
        self.inflated = true
      }
      if !self.rows_done {
        self.cur_len += made
        if self.cur_len == full {
          self.finish_row()
          continue
        }
      }
      if used > 0 || made > 0 || self.inflated {
        continue
      }
    }
    // Nothing more comes from this chunk's data until there is more.
    if self.left > 0 {
      raise NeedInput
    }
    self.state = Crc
    return None
  }
}

///|
/// Takes `n` bytes of `data`, the chunk's, through the CRC.
fn Decoder::consume(self : Decoder, data : BytesView, n : Int32) -> Unit {
  self.crc = @crc32.update_bytes(self.crc, data[:n])
  self.pos += n
  self.left -= n
}

///|
/// Reverses the whole current row's filter and makes it the row waiting to
/// be handed out.
fn Decoder::finish_row(self : Decoder) -> Unit raise Stop {
  let kind = self.cur[0]
  if !@filter.unfilter(kind, self.cur, self.prev, self.pass_bytes, self.unit) {
    raise Fail(Corrupt, "filter type \{kind.to_int()}")
  }
  let row = self.cur
  self.cur = self.prev
  self.prev = row
  self.cur_len = 0
  self.ready = true
}

///|
/// Writes the waiting row into `output` if it fits, and moves on to the next
/// row, or pass.
fn Decoder::write_row(self : Decoder, output : MutArrayView[Byte]) -> Bool {
  let n = self.pass_bytes
  if n > output.length() - self.produced {
    return false
  }
  let row = self.prev
  // SAFETY: `produced + n <= output.length()` was checked above, and `row`
  // holds 1 + the bytes of a full row, at least `1 + n`.
  match self.fixed_out {
    Some(out) => blit(out, self.produced, row, 1, n)
    None =>
      for i in 0..<n {
        output.unsafe_set(self.produced + i, row.unsafe_get(1 + i))
      }
  }
  if self.rows_count == 0 {
    self.rows_pass = self.pass
    self.rows_first = self.row
    self.rows_bytes = n
  }
  self.rows_count += 1
  self.produced += n
  self.ready = false
  self.row += 1
  if self.row == self.pass_rows {
    self.start_pass(self.pass + 1)
  }
  true
}

///|
/// Copies `n` bytes of `src` from `at` into `dst` from `to`, which the
/// caller has checked both arrays hold, in one block copy: native and Wasm
/// decode the benchmarks' image 10 to 15% faster with it than byte by byte.
#cfg(not(target="js"))
fn blit(
  dst : FixedArray[Byte],
  to : Int32,
  src : FixedArray[Byte],
  at : Int32,
  n : Int32,
) -> Unit {
  FixedArray::unsafe_blit(dst, to, src, at, n)
}

///|
/// The same, byte by byte: on JS the block copy is a loop that checks every
/// index, and decoded the benchmarks' image 10% slower than this one
/// (bench/, 2026-10-22).
#cfg(target="js")
fn blit(
  dst : FixedArray[Byte],
  to : Int32,
  src : FixedArray[Byte],
  at : Int32,
  n : Int32,
) -> Unit {
  for i in 0..<n {
    dst.unsafe_set(to + i, src.unsafe_get(at + i))
  }
}

///|
/// Same as `Decoder::step`.
pub impl @codec_image.Decode for Decoder with fn step(self, input, output, end~) {
  Decoder::step(self, input, output, end~)
}

///|
/// Same as `Decoder::last_consumed`.
pub impl @codec_image.Decode for Decoder with fn last_consumed(self) {
  Decoder::last_consumed(self)
}

///|
/// Same as `Decoder::last_produced`.
pub impl @codec_image.Decode for Decoder with fn last_produced(self) {
  Decoder::last_produced(self)
}

///|
/// Same as `Decoder::reset`.
pub impl @codec_image.Decode for Decoder with fn reset(self) {
  Decoder::reset(self)
}

///|
/// Same as `Decoder::memory_usage`.
pub impl @codec_image.Decode for Decoder with fn memory_usage(self) {
  Decoder::memory_usage(self)
}

///|
/// Same as `Decoder::room_needed`.
pub impl @codec_image.Decode for Decoder with fn room_needed(self) {
  Decoder::room_needed(self)
}

///|
/// Same as `Decoder::width`.
pub impl @codec_image.Decode for Decoder with fn width(self) {
  Decoder::width(self)
}

///|
/// Same as `Decoder::height`.
pub impl @codec_image.Decode for Decoder with fn height(self) {
  Decoder::height(self)
}

///|
/// Same as `Decoder::frame_x`.
pub impl @codec_image.Decode for Decoder with fn frame_x(self) {
  Decoder::frame_x(self)
}

///|
/// Same as `Decoder::frame_y`.
pub impl @codec_image.Decode for Decoder with fn frame_y(self) {
  Decoder::frame_y(self)
}

///|
/// Same as `Decoder::frame_width`.
pub impl @codec_image.Decode for Decoder with fn frame_width(self) {
  Decoder::frame_width(self)
}

///|
/// Same as `Decoder::frame_height`.
pub impl @codec_image.Decode for Decoder with fn frame_height(self) {
  Decoder::frame_height(self)
}

///|
/// Same as `Decoder::pass`.
pub impl @codec_image.Decode for Decoder with fn pass(self) {
  Decoder::pass(self)
}

///|
/// Same as `Decoder::pass_x`.
pub impl @codec_image.Decode for Decoder with fn pass_x(self) {
  Decoder::pass_x(self)
}

///|
/// Same as `Decoder::pass_y`.
pub impl @codec_image.Decode for Decoder with fn pass_y(self) {
  Decoder::pass_y(self)
}

///|
/// Same as `Decoder::pass_dx`.
pub impl @codec_image.Decode for Decoder with fn pass_dx(self) {
  Decoder::pass_dx(self)
}

///|
/// Same as `Decoder::pass_dy`.
pub impl @codec_image.Decode for Decoder with fn pass_dy(self) {
  Decoder::pass_dy(self)
}

///|
/// Same as `Decoder::rows_first`.
pub impl @codec_image.Decode for Decoder with fn rows_first(self) {
  Decoder::rows_first(self)
}

///|
/// Same as `Decoder::rows_count`.
pub impl @codec_image.Decode for Decoder with fn rows_count(self) {
  Decoder::rows_count(self)
}

///|
/// Same as `Decoder::row_bytes`.
pub impl @codec_image.Decode for Decoder with fn row_bytes(self) {
  Decoder::row_bytes(self)
}
