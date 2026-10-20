///|
/// A compressed stream and what it decodes to.
struct Vector {
  name : String
  compressed : String
  size : Int32
  sha256 : String
  /// The smallest window, in bits, that accepts the stream.
  window_bits : Int32
}

///|
fn Vector::input(self : Vector) -> Bytes {
  @base64.decode(self.compressed, ignore_whitespace=true) catch {
    _ => abort("bad base64 in vector \{self.name}")
  }
}
