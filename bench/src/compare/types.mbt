///|
/// A decoder that takes the whole input and returns the whole output.
pub(all) struct Whole {
  /// The package and its version.
  name : String
  /// Decodes all of the input, raising on what the package refuses.
  decode : (Bytes) -> Bytes raise
}

///|
/// A decoder fed in pieces: `run(input, piece, out, sink)` feeds `input`
/// `piece` bytes at a time and hands each piece of output to `sink`. `out`
/// is the size of the caller's output buffer, for the packages that write
/// into one; the others hand out buffers of their own.
pub(all) struct Pieces {
  /// The package and its version.
  name : String
  /// Whether output goes into a buffer the caller owns.
  caller_buffer : Bool
  /// Decodes `input` in pieces.
  run : (Bytes, Int32, Int32, (BytesView) -> Unit) -> Unit raise
}

///|
/// An encoder at a level.
pub(all) struct Compress {
  /// The package and its version.
  name : String
  /// The level the package compresses at when none is given.
  default_level : Int32
  /// Its highest level.
  max_level : Int32
  /// Compresses all of the input at a level.
  encode : (Bytes, Int32) -> Bytes raise
}

///|
/// Raises when a Go-style call returned an error.
fn check_io(err : @gm_io.IOError?) -> Unit raise {
  if err is Some(e) {
    raise e
  }
}

///|
/// How many input bytes the decoder running in pieces has been handed so far:
/// set before each piece goes in, for compare_stream to see how much output
/// comes out before the end of the input.
pub let fed : Ref[Int32] = { val: 0, }

///|
/// Hands `input` to `push` in pieces of `piece` bytes, saying which is last.
fn each_piece(
  input : Bytes,
  piece : Int32,
  push : (BytesView, Bool) -> Unit raise,
) -> Unit raise {
  if input.length() == 0 {
    push(input[:], true)
    return
  }
  let mut pos = 0
  while pos < input.length() {
    let next = (pos + piece).min(input.length())
    fed.val = next
    push(input[pos:next], next == input.length())
    pos = next
  }
}

///|
/// The bytes of a `FixedArray[Byte]`, as hustcer's packages return them.
fn of_fixed(a : FixedArray[Byte]) -> Bytes {
  Bytes::from_array(a[:])
}
