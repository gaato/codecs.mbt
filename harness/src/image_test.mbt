///|
/// Where the toy decoder is in its image.
priv enum Phase {
  ReadHeader
  ReadMetadata
  StartFrame
  ReadRows
  ReadCheck
  Finished
}

///|
/// A way for the toy decoder to break the image contract, for the adapter to
/// catch.
priv enum Bug {
  NoBug
  /// `room_needed` is always 0, so a step given too little room cannot
  /// write its row.
  UnknownRoom
  /// Interlaced rows are said to be one row apart, as if the pass had all
  /// the frame's rows.
  WrongLattice
  /// The frame is said to start one column right of the canvas's edge.
  FrameOffCanvas
}

///|
/// A decoder of a toy format, enough to exercise `ImageDecoder` before a
/// real image decoder exists: a 6-byte header (width and height, 16 bits
/// each, big-endian; 1 for two passes of alternate rows or 0 for one pass;
/// the length of a block of metadata), the block, the rows of each pass, one
/// byte a pixel, and a checksum byte, the sum of the pixels modulo 256. The
/// block is reported only with `report`.
struct Toy {
  report : Bool
  until : @codec_image.Until
  bug : Bug
  head : FixedArray[Byte]
  mut head_len : Int32
  mut width : Int32
  mut height : Int32
  mut passes : Int32
  mut meta : FixedArray[Byte]
  mut meta_len : Int32
  mut phase : Phase
  mut pass : Int32
  mut row : Int32
  mut cur : FixedArray[Byte]
  mut cur_len : Int32
  mut sum : Int32
  mut rows_pass : Int32
  mut rows_first : Int32
  mut rows_count : Int32
  mut consumed : Int32
  mut produced : Int32
  mut failed : (@codec_image.ErrorKind, String)?
}

///|
fn Toy::new(
  report~ : Bool = false,
  until~ : @codec_image.Until = EndOfInput,
  bug~ : Bug = NoBug,
) -> Toy {
  {
    report,
    until,
    bug,
    head: FixedArray::make(6, b'\x00'),
    head_len: 0,
    width: 0,
    height: 0,
    passes: 1,
    meta: FixedArray::make(0, b'\x00'),
    meta_len: 0,
    phase: ReadHeader,
    pass: 0,
    row: 0,
    cur: FixedArray::make(0, b'\x00'),
    cur_len: 0,
    sum: 0,
    rows_pass: 0,
    rows_first: 0,
    rows_count: 0,
    consumed: 0,
    produced: 0,
    failed: None,
  }
}

///|
/// Pass `p` holds rows `p`, `p + passes`, ... of the frame.
fn Toy::pass_rows(self : Toy, p : Int32) -> Int32 {
  if self.width == 0 || self.height <= p {
    0
  } else {
    (self.height - p + self.passes - 1) / self.passes
  }
}

///|
/// Moves to the first pass from `p` on that has rows, or to the checksum.
fn Toy::seek_pass(self : Toy, p : Int32) -> Unit {
  let mut p = p
  while p < self.passes && self.pass_rows(p) == 0 {
    p += 1
  }
  self.pass = p
  self.row = 0
  self.phase = if p < self.passes { ReadRows } else { ReadCheck }
}

///|
fn Toy::fail(
  self : Toy,
  kind : @codec_image.ErrorKind,
  message : String,
) -> @codec_image.Status raise @codec_image.CodecError {
  self.failed = Some((kind, message))
  raise @codec_image.CodecError::CodecError(kind, message)
}

///|
fn Toy::need_input(
  self : Toy,
  end : Bool,
) -> @codec_image.Status raise @codec_image.CodecError {
  if end {
    self.fail(Truncated, "the input ends inside the image")
  } else {
    NeedMoreInput
  }
}

///|
/// Copies input from where the step has got to into `into` from `at`, up to
/// its end, and returns how far it is filled.
fn Toy::gather(
  self : Toy,
  input : BytesView,
  into : FixedArray[Byte],
  at : Int32,
) -> Int32 {
  let take = (into.length() - at).min(input.length() - self.consumed)
  for i in 0..<take {
    into[at + i] = input[self.consumed + i]
  }
  self.consumed += take
  at + take
}

///|
impl @codec_image.Decode for Toy with fn step(self, input, output, end~) {
  self.consumed = 0
  self.produced = 0
  if self.failed is Some((kind, message)) {
    raise @codec_image.CodecError::CodecError(kind, message)
  }
  for ;; {
    match self.phase {
      ReadHeader => {
        self.head_len = self.gather(input, self.head, self.head_len)
        if self.head_len < 6 {
          return self.need_input(end)
        }
        self.width = (self.head[0].to_int() << 8) | self.head[1].to_int()
        self.height = (self.head[2].to_int() << 8) | self.head[3].to_int()
        self.passes = match self.head[4] {
          b'\x00' => 1
          b'\x01' => 2
          _ =>
            return self.fail(Corrupt, "the interlace byte is neither 0 nor 1")
        }
        self.cur = FixedArray::make(self.width, b'\x00')
        self.meta = FixedArray::make(self.head[5].to_int(), b'\x00')
        self.phase = ReadMetadata
        return Header
      }
      ReadMetadata => {
        self.meta_len = self.gather(input, self.meta, self.meta_len)
        let n = self.meta.length()
        if self.meta_len < n {
          return self.need_input(end)
        }
        if !self.report || n == 0 {
          self.phase = StartFrame
          continue
        }
        if output.length() < n {
          return NeedMoreOutput
        }
        for i in 0..<n {
          output[i] = self.meta[i]
        }
        self.produced = n
        self.phase = StartFrame
        return Metadata
      }
      StartFrame => {
        self.sum = 0
        self.seek_pass(0)
        return Frame
      }
      ReadRows => {
        let w = self.width
        let first = self.row
        let mut count = 0
        while self.row < self.pass_rows(self.pass) {
          let had = self.cur_len
          self.cur_len = self.gather(input, self.cur, had)
          for i in had..<self.cur_len {
            self.sum = (self.sum + self.cur[i].to_int()) & 0xFF
          }
          if self.cur_len < w || self.produced + w > output.length() {
            break
          }
          for i in 0..<w {
            output[self.produced + i] = self.cur[i]
          }
          self.produced += w
          self.cur_len = 0
          self.row += 1
          count += 1
        }
        if count > 0 {
          self.rows_pass = self.pass
          self.rows_first = first
          self.rows_count = count
          if self.row == self.pass_rows(self.pass) {
            self.seek_pass(self.pass + 1)
          }
          return Rows
        }
        return if self.cur_len == w {
          NeedMoreOutput
        } else {
          self.need_input(end)
        }
      }
      ReadCheck => {
        if self.consumed == input.length() {
          return self.need_input(end)
        }
        let check = input[self.consumed].to_int()
        self.consumed += 1
        if check != self.sum {
          return self.fail(ChecksumMismatch, "the pixels' sum does not match")
        }
        self.phase = Finished
        return FrameEnd
      }
      Finished =>
        return if self.until is EndOfMember {
          Done
        } else if self.consumed < input.length() {
          self.fail(TrailingData, "bytes follow the image")
        } else if end {
          Done
        } else {
          NeedMoreInput
        }
    }
  }
}

///|
impl @codec_image.Decode for Toy with fn last_consumed(self) {
  self.consumed
}

///|
impl @codec_image.Decode for Toy with fn last_produced(self) {
  self.produced
}

///|
impl @codec_image.Decode for Toy with fn reset(self) {
  self.head_len = 0
  self.width = 0
  self.height = 0
  self.passes = 1
  self.meta = FixedArray::make(0, b'\x00')
  self.meta_len = 0
  self.phase = ReadHeader
  self.pass = 0
  self.row = 0
  self.cur = FixedArray::make(0, b'\x00')
  self.cur_len = 0
  self.sum = 0
  self.consumed = 0
  self.produced = 0
  self.failed = None
}

///|
impl @codec_image.Decode for Toy with fn memory_usage(self) {
  self.cur.length() + self.meta.length()
}

///|
impl @codec_image.Decode for Toy with fn room_needed(self) {
  match (self.bug, self.phase) {
    (UnknownRoom, _) => 0
    (_, ReadMetadata) if self.report => self.meta.length()
    (_, ReadRows) => self.width
    _ => 0
  }
}

///|
impl @codec_image.Decode for Toy with fn width(self) {
  self.width
}

///|
impl @codec_image.Decode for Toy with fn height(self) {
  self.height
}

///|
impl @codec_image.Decode for Toy with fn frame_x(self) {
  if self.bug is FrameOffCanvas {
    1
  } else {
    0
  }
}

///|
impl @codec_image.Decode for Toy with fn frame_y(_) {
  0
}

///|
impl @codec_image.Decode for Toy with fn frame_width(self) {
  self.width
}

///|
impl @codec_image.Decode for Toy with fn frame_height(self) {
  self.height
}

///|
impl @codec_image.Decode for Toy with fn pass(self) {
  self.rows_pass
}

///|
impl @codec_image.Decode for Toy with fn pass_x(_) {
  0
}

///|
impl @codec_image.Decode for Toy with fn pass_y(self) {
  self.rows_pass
}

///|
impl @codec_image.Decode for Toy with fn pass_dx(_) {
  1
}

///|
impl @codec_image.Decode for Toy with fn pass_dy(self) {
  if self.bug is WrongLattice {
    1
  } else {
    self.passes
  }
}

///|
impl @codec_image.Decode for Toy with fn rows_first(self) {
  self.rows_first
}

///|
impl @codec_image.Decode for Toy with fn rows_count(self) {
  self.rows_count
}

///|
impl @codec_image.Decode for Toy with fn row_bytes(self) {
  self.width
}

///|
/// A toy image of `width` by `height` pixels, in two passes when
/// `interlaced`, with `metadata` before its rows and its checksum after
/// them, plus `wrong` (0 for the right checksum).
fn toy_image(
  width : Int32,
  height : Int32,
  interlaced~ : Bool = false,
  metadata~ : Bytes = b"",
  wrong~ : Int32 = 0,
) -> Bytes {
  let out = [
    (width >> 8).to_byte(),
    width.to_byte(),
    (height >> 8).to_byte(),
    height.to_byte(),
    if interlaced {
      b'\x01'
    } else {
      b'\x00'
    },
    metadata.length().to_byte(),
    ..metadata,
  ]
  let mut sum = 0
  for i in 0..<(width * height) {
    let pixel = (i * 7 + 3) & 0xFF
    out.push(pixel.to_byte())
    sum = (sum + pixel) & 0xFF
  }
  out.push(((sum + wrong) & 0xFF).to_byte())
  Bytes::from_array(out)
}

///|
test "image decoder: answers become events, rows the output" {
  let image = toy_image(2, 3, interlaced=true, metadata=b"note")
  let describe = (_ : Toy, status : @codec_image.Status) => {
    if status is Header {
      "gray8"
    } else {
      ""
    }
  }
  let run = @codec_harness.drive(
    @codec_harness.ImageDecoder::new(Toy::new(report=true), describe~),
    image,
  )
  debug_inspect(
    run.events,
    content=(
      #|[
      #|  "header 2x3 gray8",
      #|  "metadata 4",
      #|  "frame 0,0 2x3",
      #|  "pass 0 at 0,0 by 1,2",
      #|  "pass 1 at 0,1 by 1,2",
      #|  "frame end",
      #|]
    ),
  )
  // The block, then pass 0's rows 0 and 2, then pass 1's row 1.
  inspect(
    run.output,
    content=(
      #|b"note\x03\x0a\x11\x18\x1f&"
    ),
  )
  assert_true(run.error is None)
}

///|
test "image decoder: a room of one byte is one row a step" {
  let image = toy_image(4, 6)
  let make = () => @codec_harness.ImageDecoder::new(Toy::new())
  // Header, Frame, the six rows, FrameEnd, Done.
  let one = @codec_harness.drive(
    make(),
    image,
    output_sizes=@codec_harness.Sizes::fixed(1),
  )
  inspect(one.steps, content="10")
  // Header, Frame, all six rows, FrameEnd, Done.
  let all = @codec_harness.drive(make(), image)
  inspect(all.steps, content="5")
  assert_true(one.agrees(all))
}

///|
test "image decoder: every check holds a decoder that keeps the contract" {
  let images = [
    toy_image(0, 0),
    toy_image(1, 1),
    toy_image(3, 0, interlaced=true),
    toy_image(5, 7, interlaced=true),
    toy_image(13, 4, metadata=b"a block longer than a row"),
    toy_image(40, 31, interlaced=true, metadata=b"m"),
  ]
  for i, image in images {
    for report in [false, true] {
      let make = () => @codec_harness.ImageDecoder::new(Toy::new(report~))
      let whole = @codec_harness.check_splits(
        make,
        image,
        memory_limit=Some(1300),
      )
      assert_true(whole.error is None)
      @codec_harness.check_truncation(make, image, whole)
      @codec_harness.check_trailing(make, image, whole, garbage=[
        b"x", b"\x00\x00",
      ])
      let first = () => {
        @codec_harness.ImageDecoder::new(Toy::new(report~, until=EndOfMember))
      }
      @codec_harness.check_member(
        first,
        image,
        images[(i + 1) % images.length()],
        whole,
      )
      @codec_harness.check_reset(make, images[(i + 2) % images.length()], image)
      let outcomes = @codec_harness.fuzz(
        make,
        image,
        seed=i.reinterpret_as_uint(),
        rounds=20,
      )
      assert_eq(outcomes.values().fold(init=0, (a, b) => a + b), 20)
    }
  }
}

///|
test "image decoder: a checksum mismatch follows the rows it covers" {
  let image = toy_image(5, 7, interlaced=true, wrong=1)
  let make = () => @codec_harness.ImageDecoder::new(Toy::new())
  let run = @codec_harness.check_error_splits(make, image, seed=7)
  assert_true(run.error is Some(ChecksumMismatch))
  inspect(run.output.length(), content="35")
  // Both passes, and no end of the frame.
  inspect(run.events.length(), content="4")
}

///|
/// The failure the checks raise for `bug` over `image`, given a byte of room
/// a step.
fn caught(bug : Bug, image : Bytes) -> String {
  try
    @codec_harness.drive(
      @codec_harness.ImageDecoder::new(Toy::new(bug~)),
      image,
      output_sizes=@codec_harness.Sizes::fixed(1),
    )
  catch {
    Failure(message) => message
    e => "raised \{e}"
  } noraise {
    _ => "no failure"
  }
}

///|
test "image decoder: decoders that break the image rules fail the checks" {
  let image = toy_image(2, 3, interlaced=true)
  assert_true(
    caught(UnknownRoom, image).contains(
      "NeedMoreOutput with 1 bytes of room for 0",
    ),
  )
  assert_true(
    caught(WrongLattice, image).contains("pass 0 left after 2 of its 3 rows"),
  )
  assert_true(
    caught(FrameOffCanvas, image).contains(
      "frame 1,0 2x3 outside the canvas 2x3",
    ),
  )
}
