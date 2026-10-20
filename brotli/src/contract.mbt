// gaato/codec_bytes's traits, so that code written against the contract
// drives these codecs. Each method is the concrete one of the same name.

///|
pub impl @codec_bytes.Decode for Decoder with fn step(self, input, output, end~) {
  self.step(input, output, end~)
}

///|
pub impl @codec_bytes.Decode for Decoder with fn last_consumed(self) {
  self.last_consumed()
}

///|
pub impl @codec_bytes.Decode for Decoder with fn last_produced(self) {
  self.last_produced()
}

///|
pub impl @codec_bytes.Decode for Decoder with fn reset(self) {
  self.reset()
}

///|
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
pub impl @codec_bytes.Encode for Encoder with fn last_consumed(self) {
  self.last_consumed()
}

///|
pub impl @codec_bytes.Encode for Encoder with fn last_produced(self) {
  self.last_produced()
}

///|
pub impl @codec_bytes.Encode for Encoder with fn reset(self) {
  self.reset()
}

///|
pub impl @codec_bytes.Encode for Encoder with fn memory_usage(self) {
  self.memory_usage()
}
