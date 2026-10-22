// The fixed-length ancillary chunks: read into fields once their CRC has
// passed, and left out (counted in `ignored_chunks`) when a value is out of
// what the specification allows. The decoder does not interpret them: it
// does not apply gamma or a color space, and leaves which of cICP, iCCP,
// sRGB and cHRM wins to the caller.

///|
/// tRNS (11.3.1.1): which pixels are transparent.
pub(all) enum Transparency {
  /// For a grayscale image: the gray level, masked to the bit depth, that is
  /// fully transparent.
  Gray(Int32)
  /// For a truecolor image: the red, green and blue samples, each masked to
  /// the bit depth, of the color that is fully transparent.
  Rgb(Int32, Int32, Int32)
  /// For an indexed-color image: the alpha of each palette entry from the
  /// first, at most one for each; entries past the end are opaque.
  Alpha(ArrayView[Byte])
} derive(Eq, @debug.Debug)

///|
/// `Transparency::equal` and `Transparency::not_equal`, the derived
/// comparison.
pub extend Transparency with Eq::{equal, not_equal}

///|
/// `Transparency::to_repr`, the derived debug representation.
pub extend Transparency with @debug.Debug::{to_repr}

///|
/// cHRM (11.3.2.1): the chromaticities of the white point and the primaries,
/// CIE 1931 x and y, each times 100,000.
pub struct Chromaticities {
  white_x : UInt32
  white_y : UInt32
  red_x : UInt32
  red_y : UInt32
  green_x : UInt32
  green_y : UInt32
  blue_x : UInt32
  blue_y : UInt32
} derive(Eq, @debug.Debug)

///|
/// `Chromaticities::equal` and `Chromaticities::not_equal`, the derived
/// comparison.
pub extend Chromaticities with Eq::{equal, not_equal}

///|
/// `Chromaticities::to_repr`, the derived debug representation.
pub extend Chromaticities with @debug.Debug::{to_repr}

///|
/// cICP (11.3.2.6): the image's color space as code points of ITU-T H.273.
pub struct CodingPoints {
  /// Color primaries (1 is BT.709 and sRGB, 9 BT.2020, 12 Display P3).
  color_primaries : Int32
  /// Transfer characteristics (13 is sRGB's, 16 PQ, 18 HLG).
  transfer_function : Int32
  /// Matrix coefficients: always 0, since PNG's samples are RGB.
  matrix_coefficients : Int32
  /// Whether the samples span their full range rather than a narrow one.
  full_range : Bool
} derive(Eq, @debug.Debug)

///|
/// `CodingPoints::equal` and `CodingPoints::not_equal`, the derived
/// comparison.
pub extend CodingPoints with Eq::{equal, not_equal}

///|
/// `CodingPoints::to_repr`, the derived debug representation.
pub extend CodingPoints with @debug.Debug::{to_repr}

///|
/// mDCV (11.3.2.7): the display the content was mastered on (SMPTE ST
/// 2086). Chromaticities are CIE 1931 x and y in units of 0.00002,
/// luminances in units of 0.0001 cd/m².
pub struct MasteringDisplay {
  red_x : Int32
  red_y : Int32
  green_x : Int32
  green_y : Int32
  blue_x : Int32
  blue_y : Int32
  white_x : Int32
  white_y : Int32
  max_luminance : UInt32
  min_luminance : UInt32
} derive(Eq, @debug.Debug)

///|
/// `MasteringDisplay::equal` and `MasteringDisplay::not_equal`, the derived
/// comparison.
pub extend MasteringDisplay with Eq::{equal, not_equal}

///|
/// `MasteringDisplay::to_repr`, the derived debug representation.
pub extend MasteringDisplay with @debug.Debug::{to_repr}

///|
/// cLLI (11.3.2.8): the content's light levels, in units of 0.0001 cd/m².
pub struct LightLevel {
  /// The brightest pixel (MaxCLL).
  max_content : UInt32
  /// The brightest frame's average (MaxFALL).
  max_frame_average : UInt32
} derive(Eq, @debug.Debug)

///|
/// `LightLevel::equal` and `LightLevel::not_equal`, the derived comparison.
pub extend LightLevel with Eq::{equal, not_equal}

///|
/// `LightLevel::to_repr`, the derived debug representation.
pub extend LightLevel with @debug.Debug::{to_repr}

///|
/// pHYs (11.3.4.1): the pixels' size, or their aspect ratio.
pub struct PhysicalSize {
  /// Pixels per unit, across.
  x : UInt32
  /// Pixels per unit, down.
  y : UInt32
  /// Whether the unit is the metre; else only the ratio is known.
  per_meter : Bool
} derive(Eq, @debug.Debug)

///|
/// `PhysicalSize::equal` and `PhysicalSize::not_equal`, the derived
/// comparison.
pub extend PhysicalSize with Eq::{equal, not_equal}

///|
/// `PhysicalSize::to_repr`, the derived debug representation.
pub extend PhysicalSize with @debug.Debug::{to_repr}

///|
/// bKGD (11.3.4.2): a background color to show the image against.
pub(all) enum Background {
  /// A gray level, for grayscale images with or without alpha.
  Gray(Int32)
  /// Red, green and blue samples, for truecolor images with or without
  /// alpha.
  Rgb(Int32, Int32, Int32)
  /// A palette index, for indexed-color images.
  Index(Int32)
} derive(Eq, @debug.Debug)

///|
/// `Background::equal` and `Background::not_equal`, the derived comparison.
pub extend Background with Eq::{equal, not_equal}

///|
/// `Background::to_repr`, the derived debug representation.
pub extend Background with @debug.Debug::{to_repr}

///|
/// The longest fixed-length chunk the decoder reads into fields: tRNS of an
/// indexed-color image, one byte for each of 256 entries.
const FIELD_BYTES : Int32 = 256

///|
/// Whether the chunk of `index` in `@rules.known` is one the decoder reads
/// into fields: cHRM, cICP, gAMA, mDCV, cLLI, sBIT, sRGB, bKGD, tRNS and
/// pHYs.
fn is_field(index : Int32) -> Bool {
  index
  is (@rules.CHRM
  | @rules.CICP
  | @rules.GAMA
  | @rules.MDCV
  | @rules.CLLI
  | @rules.SBIT
  | @rules.SRGB
  | @rules.BKGD
  | @rules.TRNS
  | @rules.PHYS)
}

///|
/// What the fixed-length ancillary chunks said, once valid.
priv struct Fields {
  mut trns : Transparency?
  alpha : FixedArray[Byte]
  sbit : FixedArray[Byte]
  mut sbit_len : Int32
  mut gamma : UInt32?
  mut chromaticities : Chromaticities?
  mut srgb : Int32?
  mut cicp : CodingPoints?
  mut mdcv : MasteringDisplay?
  mut clli : LightLevel?
  mut phys : PhysicalSize?
  mut bkgd : Background?
}

///|
fn Fields::new() -> Fields {
  {
    trns: None,
    alpha: FixedArray::make(256, b'\x00'),
    sbit: FixedArray::make(4, b'\x00'),
    sbit_len: 0,
    gamma: None,
    chromaticities: None,
    srgb: None,
    cicp: None,
    mdcv: None,
    clli: None,
    phys: None,
    bkgd: None,
  }
}

///|
fn Fields::reset(self : Fields) -> Unit {
  self.trns = None
  self.sbit_len = 0
  self.gamma = None
  self.chromaticities = None
  self.srgb = None
  self.cicp = None
  self.mdcv = None
  self.clli = None
  self.phys = None
  self.bkgd = None
}

///|
fn u16(data : FixedArray[Byte], at : Int32) -> Int32 {
  (data[at].to_int() << 8) | data[at + 1].to_int()
}

///|
fn u32(data : FixedArray[Byte], at : Int32) -> UInt32 {
  (data[at].to_uint() << 24) |
  (data[at + 1].to_uint() << 16) |
  (data[at + 2].to_uint() << 8) |
  data[at + 3].to_uint()
}

///|
/// Reads the chunk of `index`, whose `len` bytes are in `data`, into the
/// fields, for an image of `color_type` and `bit_depth` with `entries`
/// palette entries. Returns false, changing nothing, when the chunk's
/// length or values are not what the specification allows; the rules are
/// libpng's, but for tRNS's samples, whose bits above the bit depth are
/// left out where libpng keeps them and warns: libpng drops them too when
/// it expands rows, and WPT's trns-high-bits-set.png expects browsers to.
fn Fields::read(
  self : Fields,
  index : Int32,
  data : FixedArray[Byte],
  len : Int32,
  color_type : Int32,
  bit_depth : Int32,
  entries : Int32,
) -> Bool {
  let sample_max = if bit_depth == 16 { 0xFFFF } else { (1 << bit_depth) - 1 }
  match index {
    // cHRM: eight values, each at most 2^31 - 1.
    @rules.CHRM => {
      guard len == 32 else { return false }
      let v = FixedArray::makei(8, i => u32(data, 4 * i))
      guard v.iter().all(x => x <= 0x7FFFFFFF) else { return false }
      self.chromaticities = Some({
        white_x: v[0],
        white_y: v[1],
        red_x: v[2],
        red_y: v[3],
        green_x: v[4],
        green_y: v[5],
        blue_x: v[6],
        blue_y: v[7],
      })
    }
    // cICP: matrix coefficients 0, the range flag 0 or 1.
    @rules.CICP => {
      guard len == 4 && data[2] == b'\x00' && data[3] <= b'\x01' else {
        return false
      }
      self.cicp = Some({
        color_primaries: data[0].to_int(),
        transfer_function: data[1].to_int(),
        matrix_coefficients: 0,
        full_range: data[3] == b'\x01',
      })
    }
    // gAMA: from 1 to 2^31 - 1.
    @rules.GAMA => {
      guard len == 4 else { return false }
      let gamma = u32(data, 0)
      guard gamma > 0 && gamma <= 0x7FFFFFFF else { return false }
      self.gamma = Some(gamma)
    }
    @rules.MDCV => {
      guard len == 24 else { return false }
      self.mdcv = Some({
        red_x: u16(data, 0),
        red_y: u16(data, 2),
        green_x: u16(data, 4),
        green_y: u16(data, 6),
        blue_x: u16(data, 8),
        blue_y: u16(data, 10),
        white_x: u16(data, 12),
        white_y: u16(data, 14),
        max_luminance: u32(data, 16),
        min_luminance: u32(data, 20),
      })
    }
    @rules.CLLI => {
      guard len == 8 else { return false }
      self.clli = Some({
        max_content: u32(data, 0),
        max_frame_average: u32(data, 4),
      })
    }
    // sBIT: one value for each channel (three for indexed-color), each from
    // 1 to the samples' depth (8 for indexed-color).
    @rules.SBIT => {
      let channels = if color_type == 3 {
        3
      } else {
        @rules.channels(color_type)
      }
      let depth = if color_type == 3 { 8 } else { bit_depth }
      guard len == channels else { return false }
      for i in 0..<len {
        guard data[i].to_int() >= 1 && data[i].to_int() <= depth else {
          return false
        }
      }
      data.blit_to(self.sbit, len~)
      self.sbit_len = len
    }
    // sRGB: a rendering intent from 0 to 3.
    @rules.SRGB => {
      guard len == 1 && data[0] <= b'\x03' else { return false }
      self.srgb = Some(data[0].to_int())
    }
    // bKGD: an index into the palette, or samples within the bit depth.
    @rules.BKGD =>
      match color_type {
        3 => {
          guard len == 1 && data[0].to_int() < entries else { return false }
          self.bkgd = Some(Index(data[0].to_int()))
        }
        0 | 4 => {
          guard len == 2 && u16(data, 0) <= sample_max else { return false }
          self.bkgd = Some(Gray(u16(data, 0)))
        }
        _ => {
          guard len == 6 else { return false }
          let (r, g, b) = (u16(data, 0), u16(data, 2), u16(data, 4))
          guard r <= sample_max && g <= sample_max && b <= sample_max else {
            return false
          }
          self.bkgd = Some(Rgb(r, g, b))
        }
      }
    // tRNS: for grayscale and truecolor one level or color; for
    // indexed-color from 1 to the palette's entries; none with alpha.
    @rules.TRNS =>
      match color_type {
        0 => {
          guard len == 2 else { return false }
          self.trns = Some(Gray(u16(data, 0) & sample_max))
        }
        2 => {
          guard len == 6 else { return false }
          self.trns = Some(
            Rgb(
              u16(data, 0) & sample_max,
              u16(data, 2) & sample_max,
              u16(data, 4) & sample_max,
            ),
          )
        }
        3 => {
          guard len >= 1 && len <= entries else { return false }
          data.blit_to(self.alpha, len~)
          self.trns = Some(Alpha(self.alpha[:len]))
        }
        _ => return false
      }
    // pHYs: a unit of 0 (none) or 1 (the metre).
    _ => {
      guard len == 9 && data[8] <= b'\x01' else { return false }
      self.phys = Some({
        x: u32(data, 0),
        y: u32(data, 4),
        per_meter: data[8] == b'\x01',
      })
    }
  }
  true
}

///|
/// tRNS: which pixels are transparent, or `None` without a valid tRNS.
/// Valid from `Frame` until `reset`.
pub fn Decoder::transparency(self : Decoder) -> Transparency? {
  self.fields.trns
}

///|
/// sBIT: the significant bits of each channel's samples, in the order of
/// the channels (red, green and blue for indexed-color), or empty without a
/// valid sBIT. Valid from `Frame` until `reset`.
pub fn Decoder::significant_bits(self : Decoder) -> ArrayView[Byte] {
  self.fields.sbit[:self.fields.sbit_len]
}

///|
/// gAMA: the image's gamma times 100,000 (45,455 for 1/2.2), or `None`.
/// Valid from `Frame` until `reset`.
pub fn Decoder::gamma(self : Decoder) -> UInt32? {
  self.fields.gamma
}

///|
/// cHRM: the chromaticities of the white point and the primaries, or
/// `None`. Valid from `Frame` until `reset`.
pub fn Decoder::chromaticities(self : Decoder) -> Chromaticities? {
  self.fields.chromaticities
}

///|
/// sRGB: the rendering intent, from 0 (perceptual) to 3 (absolute
/// colorimetric), or `None` without a valid sRGB. Valid from `Frame` until
/// `reset`.
pub fn Decoder::srgb_intent(self : Decoder) -> Int32? {
  self.fields.srgb
}

///|
/// cICP: the color space's code points, or `None`. Valid from `Frame`
/// until `reset`.
pub fn Decoder::coding_points(self : Decoder) -> CodingPoints? {
  self.fields.cicp
}

///|
/// mDCV: the display the content was mastered on, or `None`. Valid from
/// `Frame` until `reset`.
pub fn Decoder::mastering_display(self : Decoder) -> MasteringDisplay? {
  self.fields.mdcv
}

///|
/// cLLI: the content's light levels, or `None`. Valid from `Frame` until
/// `reset`.
pub fn Decoder::light_level(self : Decoder) -> LightLevel? {
  self.fields.clli
}

///|
/// pHYs: the pixels' size or aspect ratio, or `None`. Valid from `Frame`
/// until `reset`.
pub fn Decoder::physical_size(self : Decoder) -> PhysicalSize? {
  self.fields.phys
}

///|
/// bKGD: the background color, or `None`. Valid from `Frame` until `reset`.
pub fn Decoder::background(self : Decoder) -> Background? {
  self.fields.bkgd
}

///|
/// The type of the chunk whose block the last `Metadata` wrote, as its four
/// letters. The block is the chunk's data, but for the inflated ones:
/// iCCP's is the profile's name, a NUL and the profile; zTXt's is the
/// keyword, a NUL and the text, as tEXt's is; iTXt's is the chunk's data
/// with the text inflated and the compression flag and method set to 0.
/// Valid after `Metadata`, until the next step.
pub fn Decoder::metadata_type(self : Decoder) -> String {
  @rules.type_name(self.metadata_chunk)
}
