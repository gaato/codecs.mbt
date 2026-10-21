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

///|
/// A stream of messages that each end in a sync flush, never finished: for
/// each message, the offset where its bytes end, and the length and SHA-256
/// of its text.
struct Flushed {
  name : String
  compressed : String
  messages : Array[(Int32, Int32, String)]
}
