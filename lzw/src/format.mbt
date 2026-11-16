// The flavours of LZW: how codes are packed, which codes are special, when
// codes widen, and when the table is full.

///|
/// Which LZW a stream is: GIF's, TIFF's, PDF's or Unix compress's (.Z).
/// Each fixes the bit order, the clear and end codes, the widths, and the
/// point at which codes widen, as the format's references have it.
#derive(Eq, @debug.Debug)
pub struct Format {
  /// Bits of a literal: GIF's minimum code size, 8 for the others.
  literal_bits : Int32
  /// Codes are packed from each byte's most significant bit (TIFF, PDF)
  /// rather than its least (GIF, .Z).
  msb_first : Bool
  /// Codes widen one code early, when the next code to be defined reaches
  /// a power of two rather than passes it (TIFF, PDF's default).
  early_change : Bool
  /// The widest code: 12 bits, or .Z's `max_bits` (10 to 16).
  max_bits : Int32
  /// The format is .Z: a three-byte header, no end code, and codes in
  /// groups of eight that each change of width or clear pads out.
  unix : Bool
  /// .Z's block mode: code 256 clears the table. Always true for the
  /// others, whose clear code is `1 << literal_bits`.
  block_mode : Bool
}

///|
/// Compares two formats.
pub extend Format with Eq::{equal, not_equal}

///|
/// Shows a format by its fields.
pub extend Format with @debug.Debug::{to_repr}

///|
/// GIF's LZW, as an image's data holds it once its sub-blocks are joined:
/// codes packed from each byte's least significant bit, a clear code of
/// `1 << min_code_size` and an end code after it, codes from
/// `min_code_size + 1` to 12 bits. `min_code_size` is the byte before the
/// image data, 2 to 8 (GIF allows no other; 1 is accepted, as some files
/// have it); another raises `Unsupported`.
pub fn Format::gif(min_code_size : Int32) -> Format raise @codec.CodecError {
  guard min_code_size >= 1 && min_code_size <= 8 else {
    raise @codec.CodecError(
      Unsupported,
      "a GIF minimum code size of \{min_code_size}, not 1 to 8",
    )
  }
  {
    literal_bits: min_code_size,
    msb_first: false,
    early_change: false,
    max_bits: 12,
    unix: false,
    block_mode: true,
  }
}

///|
/// TIFF's LZW (compression 5): codes packed from each byte's most
/// significant bit, clear 256 and end 257, 9 to 12 bits, widening one code
/// early, as TIFF 6.0 and libtiff have it. The older TIFF LZW, packed from
/// the least significant bit, is not this.
pub fn Format::tiff() -> Format {
  {
    literal_bits: 8,
    msb_first: true,
    early_change: true,
    max_bits: 12,
    unix: false,
    block_mode: true,
  }
}

///|
/// PDF's LZWDecode filter: TIFF's LZW, with `early_change` the filter's
/// EarlyChange (true, its default, is TIFF's; false widens codes one code
/// later).
pub fn Format::pdf(early_change~ : Bool = true) -> Format {
  { ..Format::tiff(), early_change, }
}

///|
/// Unix compress's .Z: the header `1F 9D` and a byte of flags, codes packed
/// from each byte's least significant bit, from 9 bits up to `max_bits` (10
/// to 16; another raises `Unsupported`), widening as GIF's do, no end code,
/// and in `block_mode`
/// code 256 clearing the table. An encoder writes these into the header; a
/// decoder takes them from the header, and refuses streams whose `max_bits`
/// passes its own with `LimitExceeded`, since the table grows with it.
pub fn Format::unix_compress(
  max_bits~ : Int32 = 16,
  block_mode~ : Bool = true,
) -> Format raise @codec.CodecError {
  // 9 bits is a .Z no writer gets right: compress and gzip widen to 10
  // bits once its table fills, which compress's own encoder does not.
  guard max_bits >= 10 && max_bits <= 16 else {
    raise @codec.CodecError(
      Unsupported,
      "a .Z maximum of \{max_bits} bits, not 10 to 16",
    )
  }
  {
    literal_bits: 8,
    msb_first: false,
    early_change: false,
    max_bits,
    unix: true,
    block_mode,
  }
}

///|
/// The clear code, when the format has one.
fn Format::clear_code(self : Format) -> Int32 {
  1 << self.literal_bits
}

///|
/// The end code, or -1 for .Z, which has none.
fn Format::end_code(self : Format) -> Int32 {
  if self.unix {
    -1
  } else {
    (1 << self.literal_bits) + 1
  }
}

///|
/// The first code the table defines: after the literals, and the clear
/// and end codes when there are any.
fn Format::first_code(self : Format) -> Int32 {
  if self.unix {
    if self.block_mode {
      257
    } else {
      256
    }
  } else {
    (1 << self.literal_bits) + 2
  }
}

///|
/// The width of the first code after a clear.
fn Format::initial_bits(self : Format) -> Int32 {
  if self.unix {
    9
  } else {
    self.literal_bits + 1
  }
}

///|
/// How many codes the table may define: every code of `max_bits` bits.
fn Format::table_limit(self : Format) -> Int32 {
  1 << self.max_bits
}

///|
/// The width of the next code, after `bits`, when `next` is the next code
/// the encoder would define: one wider once `next` reaches `1 << bits` (or
/// passes it, without early change), up to `max_bits`.
fn Format::width(self : Format, bits : Int32, next : Int32) -> Int32 {
  let early = if self.early_change { 1 } else { 0 }
  if bits < self.max_bits && next + early > 1 << bits {
    bits + 1
  } else {
    bits
  }
}
