///|
using @fixtures {type Vector, type Crafted, type Corruption, type Flushed}

///|
/// The vector named `name`.
fn vector(name : String) -> Vector {
  @fixtures.find(vectors, name)
}

///|
/// The kind of error `decompress` raises on `input`.
fn refusal(input : BytesView) -> @codec.ErrorKind raise {
  try decompress(input) catch {
    CodecError(kind, _) => kind
  } noraise {
    _ => fail("decoded")
  }
}

///|
/// `step_into`, for `@fixtures.drive`.
fn into(
  d : Decoder,
  input : BytesView,
  out : FixedArray[Byte],
  end : Bool,
) -> Status raise @codec.CodecError {
  d.step_into(input, out, end~)
}
