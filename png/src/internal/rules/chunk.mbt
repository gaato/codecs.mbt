///|
/// A chunk type read as a big-endian 32-bit number, as its four bytes come.
pub fn chunk_type(a : Byte, b : Byte, c : Byte, d : Byte) -> UInt32 {
  (a.to_uint() << 24) | (b.to_uint() << 16) | (c.to_uint() << 8) | d.to_uint()
}

///|
/// Whether every byte of chunk type `t` is a letter, A to Z or a to z (5.3).
pub fn is_valid_type(t : UInt32) -> Bool {
  for shift = 0; shift < 32; shift = shift + 8 {
    let c = (t >> shift) & 0xFF
    if !((c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)) {
      return false
    }
  }
  true
}

///|
/// Whether chunk type `t` is critical: bit 5 of its first byte is 0, an
/// uppercase letter (5.4). A decoder that does not know a critical chunk
/// cannot show the image.
pub fn is_critical(t : UInt32) -> Bool {
  ((t >> 29) & 1) == 0
}

///|
/// The four letters of chunk type `t`, for messages.
pub fn type_name(t : UInt32) -> String {
  let name = StringBuilder()
  for shift = 24; shift >= 0; shift = shift - 8 {
    name.write_char(((t >> shift) & 0xFF).reinterpret_as_int().unsafe_to_char())
  }
  name.to_string()
}

///|
/// The chunk types that table 7 places, critical ones first, in the order of
/// the indices `known` returns. APNG's three (acTL, fcTL, fdAT) are placed
/// as the Third Edition places them.
let known_names : FixedArray[String] = [
  "IHDR", "PLTE", "IDAT", "IEND", "cHRM", "cICP", "gAMA", "iCCP", "mDCV", "cLLI",
  "sBIT", "sRGB", "bKGD", "tRNS", "hIST", "acTL", "eXIf", "pHYs", "sPLT", "tIME",
  "iTXt", "tEXt", "zTXt", "fcTL", "fdAT",
]

///|
let known_types : FixedArray[UInt32] = FixedArray::makei(known_names.length(), i => {
  let s = known_names[i]
  chunk_type(s[0].to_byte(), s[1].to_byte(), s[2].to_byte(), s[3].to_byte())
})

///|
/// IHDR's index in `known`.
pub const IHDR : Int32 = 0

///|
/// PLTE's index in `known`.
pub const PLTE : Int32 = 1

///|
/// IDAT's index in `known`.
pub const IDAT : Int32 = 2

///|
/// IEND's index in `known`.
pub const IEND : Int32 = 3

///|
/// Where an ancillary chunk of table 7 may come, by index in `known` (the
/// critical ones are placed by `place` itself).
let placements : FixedArray[Placement] = FixedArray::makei(
  known_names.length(),
  i => {
    if i < 4 {
      Anywhere
    } else if i < 12 {
      BeforePalette
    } else if i < 14 {
      AfterPalette
    } else if i == 14 {
      WithPalette
    } else if i < 19 {
      BeforeData
    } else if i < 23 {
      Anywhere
    } else if i == 23 {
      FrameControl
    } else {
      FrameData
    }
  },
)

///|
/// Whether the chunk of each index may appear more than once (table 7:
/// IDAT, sPLT, iTXt, tEXt, zTXt, fcTL and fdAT).
let multiple : FixedArray[Bool] = FixedArray::makei(known_names.length(), i => {
  i == IDAT || i == 18 || (i >= 20 && i <= 24)
})

///|
/// The place table 7 gives an ancillary chunk.
priv enum Placement {
  /// Before PLTE and before IDAT.
  BeforePalette
  /// After PLTE and before IDAT; in an image without PLTE, before IDAT.
  AfterPalette
  /// After PLTE and before IDAT, and only with PLTE (hIST).
  WithPalette
  /// Before IDAT.
  BeforeData
  /// One before IDAT, any number after it (fcTL).
  FrameControl
  /// After IDAT (fdAT).
  FrameData
  /// Anywhere between IHDR and IEND.
  Anywhere
}

///|
/// The index of chunk type `t` among those table 7 places, or -1 for a type
/// it does not know.
pub fn known(t : UInt32) -> Int32 {
  for i in 0..<known_types.length() {
    if known_types[i] == t {
      return i
    }
  }
  -1
}

///|
/// Where the decoder is among the chunks of an image, as table 7 sees it.
pub(all) enum Position {
  /// Nothing read yet: IHDR comes first.
  BeforeHeader
  /// IHDR read, and neither PLTE nor IDAT.
  AfterHeader
  /// PLTE read, no IDAT yet.
  AfterPalette
  /// The last chunk was IDAT.
  InData
  /// The IDAT chunks have ended.
  AfterData
} derive(Eq, @debug.Debug)

///|
/// `Position::equal` and `Position::not_equal`, the derived comparison.
pub extend Position with Eq::{equal, not_equal}

///|
/// `Position::to_repr`, the derived debug representation.
pub extend Position with @debug.Debug::{to_repr}

///|
/// What a decoder does with a chunk, from where it comes.
pub(all) enum Verdict {
  /// Read it.
  Accept
  /// Leave it out, and count it: an ancillary chunk out of place or a second
  /// copy of one that may come once (13.2).
  Ignore
  /// The image is refused.
  Refuse(@codec.ErrorKind, String)
} derive(Eq, @debug.Debug)

///|
/// `Verdict::equal` and `Verdict::not_equal`, the derived comparison.
pub extend Verdict with Eq::{equal, not_equal}

///|
/// `Verdict::to_repr`, the derived debug representation.
pub extend Verdict with @debug.Debug::{to_repr}

///|
/// What to do with a chunk of type `t` at `position`, given the indices of
/// the known chunks read so far (`seen`, bit `i` for index `i`) and the
/// image's color type (`color_type`, 0 before IHDR).
///
/// The rules are table 7's, with the errors of a decoder that shows the
/// image: IHDR first, once; IDAT chunks consecutive, at least one of them,
/// and for an indexed-color image after PLTE; IEND after them. An unknown
/// critical chunk is `Unsupported`. PLTE, which only an indexed-color image
/// requires, is critical there; in other images, as for ancillary chunks, a
/// PLTE out of place, a second one, or one in a grayscale image is ignored,
/// as libpng ignores it. Unknown ancillary chunks are read anywhere between
/// IHDR and IEND.
pub fn place(
  position : Position,
  t : UInt32,
  seen : UInt32,
  color_type : Int32,
) -> Verdict {
  let index = known(t)
  if position is BeforeHeader {
    return if index == IHDR {
      Accept
    } else {
      Refuse(Corrupt, "the first chunk is \{type_name(t)}, not IHDR")
    }
  }
  let before_data = position is (AfterHeader | AfterPalette)
  let indexed = color_type == 3
  match index {
    -1 =>
      if is_critical(t) {
        Refuse(Unsupported, "unknown critical chunk \{type_name(t)}")
      } else {
        Accept
      }
    IHDR => Refuse(Corrupt, "a second IHDR")
    PLTE => {
      let refusal = if (seen & (1U << PLTE)) != 0 {
        "a second PLTE"
      } else if !before_data {
        "PLTE after IDAT"
      } else {
        ""
      }
      if refusal == "" && (color_type & 2) != 0 {
        Accept
      } else if indexed {
        Refuse(Corrupt, refusal)
      } else {
        Ignore
      }
    }
    IDAT =>
      if position is AfterData {
        Refuse(Corrupt, "the IDAT chunks are not consecutive")
      } else if indexed && (seen & (1U << PLTE)) == 0 {
        Refuse(Corrupt, "an indexed-color image without PLTE before IDAT")
      } else {
        Accept
      }
    IEND =>
      if before_data {
        Refuse(Corrupt, "no IDAT before IEND")
      } else {
        Accept
      }
    _ => {
      if !multiple[index] && (seen & (1U << index)) != 0 {
        return Ignore
      }
      let fits = match placements[index] {
        BeforePalette => position is AfterHeader
        AfterPalette =>
          position is AfterPalette || (position is AfterHeader && !indexed)
        WithPalette => position is AfterPalette
        BeforeData => before_data
        FrameControl => !before_data || (seen & (1U << index)) == 0
        FrameData => !before_data
        Anywhere => true
      }
      if fits {
        Accept
      } else {
        Ignore
      }
    }
  }
}

///|
/// Where the decoder is once it has read a chunk of type `t` at `position`,
/// whatever it made of it: IHDR, PLTE and IDAT move it on, and any other
/// chunk after an IDAT ends the IDAT chunks.
pub fn after(position : Position, t : UInt32, verdict : Verdict) -> Position {
  let index = known(t)
  match position {
    BeforeHeader => AfterHeader
    AfterHeader | AfterPalette if index == IDAT => InData
    AfterHeader if index == PLTE && verdict is Accept => AfterPalette
    InData if index != IDAT => AfterData
    _ => position
  }
}
