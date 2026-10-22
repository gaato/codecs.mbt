///|
/// An image decoder under the checks. Its answers become the checks' stops:
/// `Header`, `Frame`, `FrameEnd`, `Metadata` and the first `Rows` of each
/// pass are events, with the values their accessors report, and any other
/// `Rows` is `Wrote`. A transcript is then the rows and the blocks of
/// metadata, one after another, and the events: the same for every split,
/// or the decoder broke rule 5 of the image contract.
///
/// A decoder that writes whole rows cannot fill an arbitrary number of
/// bytes, so the room a step is given is rounded up to a multiple of the
/// decoder's `room_needed`, when it is known: a room of 1 is one row a step.
/// Every step is also checked against the image rules that do not depend on
/// the split: what a step may write, the order of the answers, frames
/// inside the canvas, and passes that each give all the rows their lattice
/// makes, in order.
pub struct ImageDecoder[D] {
  decoder : D
  /// What the format adds to an event: the pixel layout to the header,
  /// whether a frame is part of the animation, a block's chunk type. Empty
  /// for nothing.
  describe : (D, @codec_image.Status) -> String
  /// Whether `Header` was reported.
  priv mut seen_header : Bool
  /// Whether a frame began and has not ended.
  priv mut in_frame : Bool
  /// The pass of the last `Rows`, -1 before the first `Rows` of a frame.
  priv mut pass : Int32
  /// The row of the pass the next `Rows` must start at.
  priv mut next_row : Int32
  /// The rows the pass has, from its lattice and the frame's height.
  priv mut pass_rows : Int32
  /// The pass's lattice and row size, which stay the same through it.
  priv mut pass_x : Int32
  priv mut pass_y : Int32
  priv mut pass_dx : Int32
  priv mut pass_dy : Int32
  priv mut row_bytes : Int32
}

///|
/// `describe` adds the format's own text to the events (nothing by default),
/// so that a decoder that reports, say, a wrong pixel layout under some
/// split fails the checks too.
pub fn[D] ImageDecoder::new(
  decoder : D,
  describe~ : (D, @codec_image.Status) -> String = (_, _) => "",
) -> ImageDecoder[D] {
  {
    decoder,
    describe,
    seen_header: false,
    in_frame: false,
    pass: -1,
    next_row: 0,
    pass_rows: 0,
    pass_x: 0,
    pass_y: 0,
    pass_dx: 0,
    pass_dy: 0,
    row_bytes: 0,
  }
}

///|
pub extend ImageDecoder with Stepper::{step, reset, memory_usage}

///|
pub impl[D : @codec_image.Decode] Stepper for ImageDecoder[D] with fn step(
  self,
  input,
  room,
  end~,
) {
  let unit = self.decoder.room_needed()
  let room = if unit > 0 { round_up(room, unit) } else { room }
  let out = FixedArray::make(room, b'\x00')
  let stop : Stop = try self.decoder.step(input, out.mut_view(), end~) catch {
    @codec.CodecError(kind, message) => {
      check_counts(input, room, self.decoder.last_consumed(), 0)
      if self.decoder.last_produced() != 0 {
        fail(
          "a step that raised \{@debug.to_string(kind)} wrote \{self.decoder.last_produced()} bytes",
        )
      }
      Raised(kind, message)
    }
  } noraise {
    status => {
      check_counts(
        input,
        room,
        self.decoder.last_consumed(),
        self.decoder.last_produced(),
      )
      self.observe(status, self.decoder.last_produced(), room)
    }
  }
  let produced = self.decoder.last_produced()
  {
    consumed: self.decoder.last_consumed(),
    produced: Bytes::from_array(out[:produced]),
    stop,
  }
}

///|
/// `room` up to a multiple of `unit`, at least `unit`.
fn round_up(room : Int32, unit : Int32) -> Int32 {
  let unit = unit.to_int64()
  ((room.to_int64() + unit - 1L) / unit * unit).to_int()
}

///|
/// The stop that `status` is, once the step that answered it, having written
/// `produced` bytes into `room`, is checked against the rules.
fn[D : @codec_image.Decode] ImageDecoder::observe(
  self : ImageDecoder[D],
  status : @codec_image.Status,
  produced : Int32,
  room : Int32,
) -> Stop raise {
  let d = self.decoder
  if produced != 0 && !(status is (Rows | Metadata)) {
    fail("\{@debug.to_string(status)} wrote \{produced} bytes")
  }
  match status {
    Header => {
      if self.seen_header {
        fail("a second Header")
      }
      if d.width() < 0 || d.height() < 0 {
        fail("a canvas of \{d.width()}x\{d.height()}")
      }
      self.seen_header = true
      self.event("header \{d.width()}x\{d.height()}", status)
    }
    Frame => {
      if !self.seen_header {
        fail("Frame before Header")
      }
      if self.in_frame {
        fail("Frame before the last frame's FrameEnd")
      }
      let (x, y, w, h) = (
        d.frame_x(),
        d.frame_y(),
        d.frame_width(),
        d.frame_height(),
      )
      if x < 0 ||
        y < 0 ||
        w < 0 ||
        h < 0 ||
        x.to_int64() + w.to_int64() > d.width().to_int64() ||
        y.to_int64() + h.to_int64() > d.height().to_int64() {
        fail(
          "frame \{x},\{y} \{w}x\{h} outside the canvas \{d.width()}x\{d.height()}",
        )
      }
      self.in_frame = true
      self.pass = -1
      self.event("frame \{x},\{y} \{w}x\{h}", status)
    }
    Rows => self.rows(produced)
    Metadata => self.event("metadata \{produced}", status)
    FrameEnd => {
      if !self.in_frame {
        fail("FrameEnd outside a frame")
      }
      self.finish_pass()
      self.in_frame = false
      self.event("frame end", status)
    }
    Done => {
      if !self.seen_header {
        fail("Done before Header")
      }
      if self.in_frame {
        fail("Done inside a frame")
      }
      Done
    }
    NeedMoreInput => NeedMoreInput
    NeedMoreOutput => {
      if room >= d.room_needed() {
        fail("NeedMoreOutput with \{room} bytes of room for \{d.room_needed()}")
      }
      NeedMoreOutput
    }
  }
}

///|
/// `text`, followed by what the format adds for `status`.
fn[D] ImageDecoder::event(
  self : ImageDecoder[D],
  text : String,
  status : @codec_image.Status,
) -> Stop {
  let more = (self.describe)(self.decoder, status)
  Event(if more == "" { text } else { "\{text} \{more}" })
}

///|
/// Checks the `Rows` of a step that wrote `produced` bytes: they continue
/// the current pass where it stopped, or start a new one, later than it,
/// from its row 0. The first `Rows` of a pass is an event.
fn[D : @codec_image.Decode] ImageDecoder::rows(
  self : ImageDecoder[D],
  produced : Int32,
) -> Stop raise {
  let d = self.decoder
  if !self.in_frame {
    fail("Rows outside a frame")
  }
  let count = d.rows_count()
  let bytes = d.row_bytes()
  if count < 1 ||
    bytes < 1 ||
    count.to_int64() * bytes.to_int64() != produced.to_int64() {
    fail("Rows wrote \{produced} bytes as \{count} rows of \{bytes}")
  }
  let pass = d.pass()
  let (px, py, dx, dy) = (d.pass_x(), d.pass_y(), d.pass_dx(), d.pass_dy())
  let first = pass != self.pass
  if first {
    if pass < self.pass {
      fail("pass \{pass} after pass \{self.pass}")
    }
    self.finish_pass()
    let w = d.frame_width()
    let h = d.frame_height()
    if px < 0 || px >= w || py < 0 || py >= h || dx < 1 || dy < 1 {
      fail(
        "pass \{pass} at \{px},\{py} by \{dx},\{dy} does not start inside the frame \{w}x\{h}",
      )
    }
    self.pass = pass
    self.next_row = 0
    self.pass_rows = (h - py - 1) / dy + 1
    self.pass_x = px
    self.pass_y = py
    self.pass_dx = dx
    self.pass_dy = dy
    self.row_bytes = bytes
  } else if px != self.pass_x ||
    py != self.pass_y ||
    dx != self.pass_dx ||
    dy != self.pass_dy ||
    bytes != self.row_bytes {
    fail("pass \{pass} changed its lattice or its row size")
  }
  if d.rows_first() != self.next_row {
    fail(
      "rows of pass \{pass} from row \{d.rows_first()}, not \{self.next_row}",
    )
  }
  if count > self.pass_rows - self.next_row {
    fail(
      "pass \{pass} wrote rows \{self.next_row} to \{self.next_row.to_int64() + count.to_int64() - 1L} of its \{self.pass_rows}",
    )
  }
  self.next_row += count
  if first {
    self.event("pass \{pass} at \{px},\{py} by \{dx},\{dy}", Rows)
  } else {
    Wrote
  }
}

///|
/// Fails unless the current pass, if any, gave all its rows.
fn[D] ImageDecoder::finish_pass(self : ImageDecoder[D]) -> Unit raise {
  if self.pass >= 0 && self.next_row != self.pass_rows {
    fail(
      "pass \{self.pass} left after \{self.next_row} of its \{self.pass_rows} rows",
    )
  }
}

///|
pub impl[D : @codec_image.Decode] Stepper for ImageDecoder[D] with fn reset(
  self,
) {
  self.decoder.reset()
  self.seen_header = false
  self.in_frame = false
  self.pass = -1
  self.next_row = 0
  self.pass_rows = 0
}

///|
pub impl[D : @codec_image.Decode] Stepper for ImageDecoder[D] with fn memory_usage(
  self,
) {
  self.decoder.memory_usage()
}
