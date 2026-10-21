// Generated from parts/huffman/enough.mbt by scripts/gen_parts.mbtx: edit it there, not here.
// How large a decoding table can get: the bounds a decoder sizes its tables
// by.

///|
/// The most entries `Builder::build` takes for a code over `alphabet`
/// symbols with codes up to 15 bits and a `1 << root_bits` root, for the
/// alphabets and roots DEFLATE and Brotli decoders use; `None` for others.
/// These are zlib's `enough` (examples/enough.c), the largest over every
/// complete code, which also bounds the incomplete codes DEFLATE accepts (a
/// lone code takes the root alone).
pub fn max_entries(alphabet~ : Int32, root_bits~ : Int32) -> Int32? {
  match (alphabet, root_bits) {
    // DEFLATE's literal and length codes.
    (286, 9) => Some(852)
    (288, 10) => Some(1334)
    (288, 11) => Some(2342)
    // DEFLATE's distance codes, with and without the two unused symbols.
    (30, 6) => Some(592)
    (30, 8) => Some(400)
    (32, 8) => Some(402)
    // Brotli's literal codes.
    (256, 8) => Some(630)
    _ => None
  }
}
