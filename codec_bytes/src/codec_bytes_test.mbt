///|
/// A decoder of the identity format: output is input. Enough to exercise the
/// traits from outside the package.
struct Copy {
  mut consumed : Int32
  mut produced : Int32
}

///|
impl @codec_bytes.Decode for Copy with fn step(self, input, output, end~) {
  let n = input.length().min(output.length())
  for i in 0..<n {
    output[i] = input[i]
  }
  self.consumed = n
  self.produced = n
  if n < input.length() {
    NeedMoreOutput
  } else if end {
    Done
  } else {
    NeedMoreInput
  }
}

///|
impl @codec_bytes.Decode for Copy with fn last_consumed(self) {
  self.consumed
}

///|
impl @codec_bytes.Decode for Copy with fn last_produced(self) {
  self.produced
}

///|
impl @codec_bytes.Decode for Copy with fn reset(self) {
  self.consumed = 0
  self.produced = 0
}

///|
impl @codec_bytes.Decode for Copy with fn memory_usage(_) {
  0
}

///|
test "a decoder is usable as a trait object" {
  let decoder : &@codec_bytes.Decode = { consumed: 0, produced: 0, }
  let out = FixedArray::make(3, b'\x00')
  assert_eq(decoder.step(b"abcde", out.mut_view(), end=true), NeedMoreOutput)
  assert_eq(decoder.last_produced(), 3)
  assert_eq(decoder.step(b"de", out.mut_view(), end=true), Done)
  assert_eq(decoder.last_consumed(), 2)
}
