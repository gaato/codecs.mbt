///|
/// Where the toy decoder is in its image.
priv enum Phase {
  ReadHeader
  StartFrame
  ReadRows
  EndFrame
  Finished
}

///|
/// A decoder of a toy format, enough to exercise the trait from outside the
/// package: a 5-byte header (width and height, 16 bits each, big-endian,
/// then 1 for two passes of alternate rows or 0 for one pass), then the rows
/// of each pass, one byte a pixel, then nothing.
struct Toy {
  head : FixedArray[Byte]
  mut head_len : Int32
  mut width : Int32
  mut height : Int32
  mut passes : Int32
  mut phase : Phase
  mut pass : Int32
  mut row : Int32
  mut cur : FixedArray[Byte]
  mut cur_len : Int32
  mut rows_pass : Int32
  mut rows_first : Int32
  mut rows_count : Int32
  mut consumed : Int32
  mut produced : Int32
  mut failed : (@codec_image.ErrorKind, String)?
}

///|
fn Toy::new() -> Toy {
  {
    head: FixedArray::make(5, b'\x00'),
    head_len: 0,
    width: 0,
    height: 0,
    passes: 1,
    phase: ReadHeader,
    pass: 0,
    row: 0,
    cur: FixedArray::make(0, b'\x00'),
    cur_len: 0,
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
/// Moves to the first pass from `p` on that has rows, or to the frame's end.
fn Toy::seek_pass(self : Toy, p : Int32) -> Unit {
  let mut p = p
  while p < self.passes && self.pass_rows(p) == 0 {
    p += 1
  }
  self.pass = p
  self.row = 0
  self.phase = if p < self.passes { ReadRows } else { EndFrame }
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
impl @codec_image.Decode for Toy with fn step(self, input, output, end~) {
  self.consumed = 0
  self.produced = 0
  if self.failed is Some((kind, message)) {
    raise @codec_image.CodecError::CodecError(kind, message)
  }
  match self.phase {
    ReadHeader => {
      while self.head_len < 5 && self.consumed < input.length() {
        self.head[self.head_len] = input[self.consumed]
        self.head_len += 1
        self.consumed += 1
      }
      if self.head_len < 5 {
        return self.need_input(end)
      }
      self.width = (self.head[0].to_int() << 8) | self.head[1].to_int()
      self.height = (self.head[2].to_int() << 8) | self.head[3].to_int()
      self.passes = match self.head[4] {
        b'\x00' => 1
        b'\x01' => 2
        _ => return self.fail(Corrupt, "the interlace byte is neither 0 nor 1")
      }
      self.cur = FixedArray::make(self.width, b'\x00')
      self.phase = StartFrame
      Header
    }
    StartFrame => {
      self.seek_pass(0)
      Frame
    }
    ReadRows => {
      let w = self.width
      let first = self.row
      let mut count = 0
      while self.row < self.pass_rows(self.pass) {
        let take = (w - self.cur_len).min(input.length() - self.consumed)
        for i in 0..<take {
          self.cur[self.cur_len + i] = input[self.consumed + i]
        }
        self.cur_len += take
        self.consumed += take
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
        Rows
      } else if self.cur_len == w {
        NeedMoreOutput
      } else {
        self.need_input(end)
      }
    }
    EndFrame => {
      self.phase = Finished
      FrameEnd
    }
    Finished =>
      if input.length() > 0 {
        self.fail(TrailingData, "bytes follow the image")
      } else if end {
        Done
      } else {
        NeedMoreInput
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
  self.phase = ReadHeader
  self.pass = 0
  self.row = 0
  self.cur = FixedArray::make(0, b'\x00')
  self.cur_len = 0
  self.consumed = 0
  self.produced = 0
  self.failed = None
}

///|
impl @codec_image.Decode for Toy with fn memory_usage(self) {
  self.cur.length()
}

///|
impl @codec_image.Decode for Toy with fn room_needed(self) {
  if self.phase is ReadRows {
    self.width
  } else {
    0
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
impl @codec_image.Decode for Toy with fn frame_x(_) {
  0
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
  self.passes
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
/// Drives `decoder` over `input` given whole, with `room` bytes of output a
/// step, and describes what it reported: one line an answer, each `Rows`
/// with its pass, first row and count, and its bytes.
fn run(decoder : &@codec_image.Decode, input : Bytes, room : Int32) -> String {
  let out = FixedArray::make(room, b'\x00')
  let lines = []
  let mut rest = input[:]
  for ;; {
    let status = decoder.step(rest, out.mut_view(), end=true) catch {
      CodecError(kind, _) => {
        lines.push("raised \{@debug.to_string(kind)}")
        break
      }
    }
    rest = rest[decoder.last_consumed():]
    match status {
      Rows => {
        let n = decoder.last_produced()
        lines.push(
          "rows pass \{decoder.pass()} at \{decoder.rows_first()} x\{decoder.rows_count()}: \{@debug.to_string(Bytes::from_array(out[:n]))}",
        )
      }
      NeedMoreOutput => {
        lines.push("need \{decoder.room_needed()} bytes of room")
        break
      }
      Done => {
        lines.push("done")
        break
      }
      other => lines.push(@debug.to_string(other))
    }
  }
  lines.join("\n")
}

///|
test "a decoder is usable as a trait object" {
  // 2 x 3, two passes: rows 0 and 2, then row 1.
  let image = b"\x00\x02\x00\x03\x01abcdef"
  inspect(
    run(Toy::new(), image, 4),
    content=(
      #|Header
      #|Frame
      #|rows pass 0 at 0 x2: <Bytes: [0x61, 0x62, 0x63, 0x64]>
      #|rows pass 1 at 0 x1: <Bytes: [0x65, 0x66]>
      #|FrameEnd
      #|done
    ),
  )
  inspect(
    run(Toy::new(), image, 1),
    content=(
      #|Header
      #|Frame
      #|need 2 bytes of room
    ),
  )
  inspect(
    run(Toy::new(), b"\x00\x02\x00\x03\x00abcdefg", 6),
    content=(
      #|Header
      #|Frame
      #|rows pass 0 at 0 x3: <Bytes: [0x61, 0x62, 0x63, 0x64, 0x65, 0x66]>
      #|FrameEnd
      #|raised TrailingData
    ),
  )
}
