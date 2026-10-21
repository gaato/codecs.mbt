///|
using @fixtures {type Vector, type Crafted, type Corruption}

///|
/// The vector named `name`.
fn vector(name : String) -> Vector {
  @fixtures.find(vectors, name)
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
