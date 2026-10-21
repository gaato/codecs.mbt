///|
/// What the two header bytes, CMF and FLG, say.
pub(all) struct Header {
  /// The base-2 logarithm of the window the encoder used, CINFO + 8: 8 to 15.
  window_bits : Int32
  /// FLEVEL: how hard the encoder tried, 0 (fastest) to 3 (slowest).
  level : Int32
  /// FDICT: a preset dictionary's Adler-32 (DICTID) follows.
  dictionary : Bool
} derive(Eq, @debug.Debug)

///|
/// Reads CMF and FLG, in the order zlib checks them: the header check, the
/// compression method (8, DEFLATE, is the only one), then the window (at most
/// 32 KiB).
pub fn parse(cmf : Byte, flg : Byte) -> Result[Header, String] {
  let cmf = cmf.to_int()
  let flg = flg.to_int()
  if (cmf * 256 + flg) % 31 != 0 {
    return Err("the header check (FCHECK) fails")
  }
  let cm = cmf & 15
  if cm != 8 {
    return Err("compression method \{cm} is not DEFLATE (8)")
  }
  let cinfo = cmf >> 4
  if cinfo > 7 {
    return Err("a window of 2^\{cinfo + 8} bytes is over 32 KiB")
  }
  Ok({ window_bits: cinfo + 8, level: flg >> 6, dictionary: (flg & 0x20) != 0, })
}

///|
/// The big-endian value of four bytes: DICTID, or the Adler-32 of the
/// trailer.
pub fn be32(b : BytesView) -> UInt32 {
  (b[0].to_uint() << 24) |
  (b[1].to_uint() << 16) |
  (b[2].to_uint() << 8) |
  b[3].to_uint()
}

///|
/// Checks the trailer, the Adler-32 of the data, against `adler`.
pub fn check_trailer(
  adler : UInt32,
  trailer : BytesView,
) -> Result[Unit, String] {
  if be32(trailer) != adler {
    return Err("the Adler-32 of the data does not match the stream's")
  }
  Ok(())
}

///|
pub extend Header with Eq::{equal, not_equal}

///|
pub extend Header with @debug.Debug::{to_repr}
