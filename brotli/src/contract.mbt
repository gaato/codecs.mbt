// gaato/codec_bytes's traits, so that code written against the contract
// drives these codecs. Each method is the concrete one of the same name.

///|
/// Decodes through `Decoder::step`.
pub impl @codec_bytes.Decode for Decoder with fn step(self, input, output, end~) {
  self.step(input, output, end~)
}

///|
/// Same as `Decoder::last_consumed`: input bytes the last step consumed.
pub impl @codec_bytes.Decode for Decoder with fn last_consumed(self) {
  self.last_consumed()
}

///|
/// Same as `Decoder::last_produced`: output bytes the last step wrote.
pub impl @codec_bytes.Decode for Decoder with fn last_produced(self) {
  self.last_produced()
}

///|
/// Same as `Decoder::reset`: back to the state of a new decoder with the same options.
pub impl @codec_bytes.Decode for Decoder with fn reset(self) {
  self.reset()
}

///|
/// Same as `Decoder::memory_usage`: bytes allocated for the current stream.
pub impl @codec_bytes.Decode for Decoder with fn memory_usage(self) {
  self.memory_usage()
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
  self.step(input, output, action~)
}

///|
/// Same as `Encoder::last_consumed`: input bytes the last step consumed.
pub impl @codec_bytes.Encode for Encoder with fn last_consumed(self) {
  self.last_consumed()
}

///|
/// Same as `Encoder::last_produced`: output bytes the last step wrote.
pub impl @codec_bytes.Encode for Encoder with fn last_produced(self) {
  self.last_produced()
}

///|
/// Same as `Encoder::reset`: back to the state of a new encoder with the same options.
pub impl @codec_bytes.Encode for Encoder with fn reset(self) {
  self.reset()
}

///|
/// Same as `Encoder::memory_usage`: bytes allocated for the current stream.
pub impl @codec_bytes.Encode for Encoder with fn memory_usage(self) {
  self.memory_usage()
}
