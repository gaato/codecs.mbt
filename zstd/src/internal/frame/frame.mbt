// The sizes in a frame header (RFC 8878 section 3.1.1.1), from the bytes
// that give them: Frame_Header_Descriptor and Window_Descriptor.

///|
/// The size of the Dictionary_ID field (Dictionary_ID_Flag) a frame header
/// descriptor, a byte, calls for.
pub fn dictionary_id_size(
  descriptor : Int32,
) -> Int32 where {
  proof_require: is_byte(descriptor),
  proof_ensure: result => result == spec_did_size(descriptor),
} {
  let flag = descriptor % 4
  if flag == 0 {
    0
  } else if flag == 1 {
    1
  } else if flag == 2 {
    2
  } else {
    4
  }
}

///|
/// The size of the Frame_Content_Size field (Frame_Content_Size_Flag) a
/// frame header descriptor, a byte, calls for: a single-segment frame always
/// has one.
pub fn content_size_size(
  descriptor : Int32,
) -> Int32 where {
  proof_require: is_byte(descriptor),
  proof_ensure: result => result == spec_fcs_size(descriptor),
} {
  let flag = descriptor / 64
  if flag == 0 {
    if descriptor / 32 % 2 != 0 {
      1
    } else {
      0
    }
  } else if flag == 1 {
    2
  } else if flag == 2 {
    4
  } else {
    8
  }
}

///|
/// The length of the frame header that starts with the descriptor
/// `descriptor`, a byte, descriptor included; `None` when its reserved bit
/// is set.
pub fn header_len(
  descriptor : Int32,
) -> Int32? where {
  proof_require: is_byte(descriptor),
  proof_ensure: result => header_len_post(descriptor, result),
} {
  if descriptor / 8 % 2 != 0 {
    None
  } else {
    let window_descriptor_size = if descriptor / 32 % 2 != 0 { 0 } else { 1 }
    Some(
      1 +
      window_descriptor_size +
      dictionary_id_size(descriptor) +
      content_size_size(descriptor),
    )
  }
}

///|
/// The window a Window_Descriptor byte asks for (RFC 8878 section
/// 3.1.1.1.2): `2^(10 + Exponent)` and `Mantissa` eighths of it more, at
/// most 2^41 + 7 * 2^38.
pub fn window_size(
  window_descriptor : Int32,
) -> UInt64 where {
  proof_require: is_byte(window_descriptor),
  proof_ensure: result => window_post(window_descriptor, result),
} {
  let base = shl1_u64(10 + window_descriptor / 8)
  base + base / 8UL * mantissa_u64(window_descriptor % 8)
}
