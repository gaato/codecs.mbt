// APNG (the third edition's 4.9 and 11.3.6): acTL says the image is
// animated, each fcTL describes a frame, and fdAT carries the data of the
// frames after the default image, each with a sequence number that fcTL
// shares. A frame is reported at its first data chunk, so that everything
// before it is known, and ends at the next fcTL or IEND: text chunks may
// come between the fdAT chunks of one frame.

///|
/// What to do with a frame's rectangle once it has been shown, before the
/// next frame is drawn (dispose_op).
pub(all) enum Dispose {
  /// Leave the canvas as it is.
  Keep
  /// Clear the rectangle to fully transparent black.
  Background
  /// Put back what the rectangle held before the frame was drawn.
  Previous
} derive(Eq, @debug.Debug)

///|
/// `Dispose::equal` and `Dispose::not_equal`, the derived comparison.
pub extend Dispose with Eq::{equal, not_equal}

///|
/// `Dispose::to_repr`, the derived debug representation.
pub extend Dispose with @debug.Debug::{to_repr}

///|
/// How a frame's pixels are put on the canvas (blend_op).
pub(all) enum Blend {
  /// They replace the rectangle's, alpha included.
  Source
  /// They are composited over the rectangle's, by their alpha.
  Over
} derive(Eq, @debug.Debug)

///|
/// `Blend::equal` and `Blend::not_equal`, the derived comparison.
pub extend Blend with Eq::{equal, not_equal}

///|
/// `Blend::to_repr`, the derived debug representation.
pub extend Blend with @debug.Debug::{to_repr}

///|
/// A frame's place and how it is shown, from its fcTL, or the whole image
/// for a default image without one.
priv struct Control {
  mut x : Int32
  mut y : Int32
  mut width : Int32
  mut height : Int32
  mut delay_numerator : Int32
  mut delay_denominator : Int32
  mut dispose : Dispose
  mut blend : Blend
}

///|
fn Control::new() -> Control {
  {
    x: 0,
    y: 0,
    width: 0,
    height: 0,
    delay_numerator: 0,
    delay_denominator: 100,
    dispose: Keep,
    blend: Source,
  }
}

///|
/// The whole image `width` x `height`, shown at once.
fn Control::whole(self : Control, width : Int32, height : Int32) -> Unit {
  self.x = 0
  self.y = 0
  self.width = width
  self.height = height
  self.delay_numerator = 0
  self.delay_denominator = 100
  self.dispose = Keep
  self.blend = Source
}

///|
fn Control::copy(self : Control, from : Control) -> Unit {
  self.x = from.x
  self.y = from.y
  self.width = from.width
  self.height = from.height
  self.delay_numerator = from.delay_numerator
  self.delay_denominator = from.delay_denominator
  self.dispose = from.dispose
  self.blend = from.blend
}

///|
/// Reads fcTL's 26 bytes in `data` (its sequence number already checked)
/// for an image `width` x `height`, refusing values that describe no frame.
/// The values are those to apply: a delay's denominator of 0 is 100, and a
/// first frame's dispose op of PREVIOUS is BACKGROUND, as 11.3.6.2 says.
fn Control::read(
  self : Control,
  data : FixedArray[Byte],
  width : Int32,
  height : Int32,
  default_image~ : Bool,
  first~ : Bool,
) -> Unit raise Stop {
  let frame_width = u32(data, 4)
  let frame_height = u32(data, 8)
  let x = u32(data, 12)
  let y = u32(data, 16)
  let dispose = data[24].to_int()
  let blend = data[25].to_int()
  if @rules.check_frame(
      width.reinterpret_as_uint(),
      height.reinterpret_as_uint(),
      frame_width,
      frame_height,
      x,
      y,
      dispose,
      blend,
      first=default_image,
    )
    is Some(message) {
    raise Fail(Corrupt, "fcTL: \{message}")
  }
  self.x = x.reinterpret_as_int()
  self.y = y.reinterpret_as_int()
  self.width = frame_width.reinterpret_as_int()
  self.height = frame_height.reinterpret_as_int()
  self.delay_numerator = u16(data, 20)
  self.delay_denominator = if u16(data, 22) == 0 { 100 } else { u16(data, 22) }
  self.dispose = match dispose {
    0 => Keep
    1 => Background
    _ => if first { Background } else { Previous }
  }
  self.blend = if blend == 0 { Source } else { Over }
}

///|
/// Whether the image is an APNG: an acTL with at least one frame came
/// before IDAT, and the decoder reads animations (`animation=true`). Valid
/// from `Frame` until `reset`.
pub fn Decoder::animated(self : Decoder) -> Bool {
  self.animated
}

///|
/// The frames of the animation acTL announces (the default image among
/// them when it is part of it), and 0 for an image that is not animated.
/// The decoder checks the count at IEND. Valid from `Frame` until `reset`.
pub fn Decoder::frame_count(self : Decoder) -> UInt32 {
  self.frames
}

///|
/// How many times acTL says to play the animation, 0 for without end.
/// Valid from `Frame` until `reset`.
pub fn Decoder::plays(self : Decoder) -> UInt32 {
  self.plays
}

///|
/// Whether the current frame is one of the animation's: every frame of
/// fdAT chunks, and the default image when an fcTL comes before IDAT. A
/// default image that is not part of the animation, and the image of a PNG
/// that is not animated, is not. Valid from `Frame` until the next `Frame`
/// or `Done`.
pub fn Decoder::in_animation(self : Decoder) -> Bool {
  self.in_animation
}

///|
/// The numerator of the current frame's delay, in seconds: how long it is
/// shown. Valid from `Frame` until the next `Frame` or `Done`.
pub fn Decoder::delay_numerator(self : Decoder) -> Int32 {
  self.control.delay_numerator
}

///|
/// The denominator of the current frame's delay, 100 when fcTL says 0.
/// Valid from `Frame` until the next `Frame` or `Done`.
pub fn Decoder::delay_denominator(self : Decoder) -> Int32 {
  self.control.delay_denominator
}

///|
/// What to do with the current frame's rectangle after it is shown;
/// PREVIOUS on the first frame comes as `Background`. Valid from `Frame`
/// until the next `Frame` or `Done`.
pub fn Decoder::dispose(self : Decoder) -> Dispose {
  self.control.dispose
}

///|
/// How the current frame's pixels go on the canvas. Valid from `Frame`
/// until the next `Frame` or `Done`.
pub fn Decoder::blend(self : Decoder) -> Blend {
  self.control.blend
}
