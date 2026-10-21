// The stream header and the length fields of the meta-block header
// (RFC 7932 sections 9.1 and 9.2).

///|
/// WBITS and the stream header's length in bits (RFC 7932 section 9.1),
/// from its first 7 bits, first bit least significant; bits past the header
/// are ignored. `None` for 0b0010001, the pattern RFC 7932 reserves: RFC
/// 9841 assigns it to large-window Brotli, which the decoder does not
/// support and reports as corrupt.
pub fn window_bits(
  header : Int32,
) -> (Int32, Int32)? where {
  proof_require: 0 <= header,
  proof_ensure: result => window_bits_post(header, result),
} {
  if @proof_bits.low_bits(header, 1) == 0 {
    Some((16, 1))
  } else {
    let n = @proof_bits.low_bits(@proof_bits.shr(header, 1), 3)
    if n != 0 {
      Some((17 + n, 4))
    } else {
      let m = @proof_bits.low_bits(@proof_bits.shr(header, 4), 3)
      if m == 0 {
        Some((17, 7))
      } else if m == 1 {
        None
      } else {
        Some((8 + m, 7))
      }
    }
  }
}

///|
/// MLEN from MNIBBLES (4 to 6) nibbles of MLEN - 1 in `bits` (section 9.2).
/// `None` when more than four nibbles end in a zero one, which RFC 7932
/// forbids.
pub fn meta_block_length(
  bits : Int32,
  nibbles : Int32,
) -> Int32? where {
  proof_require: meta_block_length_pre(bits, nibbles),
  proof_ensure: result => meta_block_length_post(bits, nibbles, result),
} {
  if nibbles > 4 && @proof_bits.shr(bits, 4 * (nibbles - 1)) == 0 {
    None
  } else {
    Some(bits + 1)
  }
}

///|
/// The length of a metadata block from MSKIPBYTES (0 to 3) bytes of
/// MSKIPLEN - 1 in `bits` (section 9.2): 0 with no bytes. `None` when more
/// than one byte ends in a zero one, which RFC 7932 forbids.
pub fn metadata_length(
  bits : Int32,
  bytes : Int32,
) -> Int32? where {
  proof_require: metadata_length_pre(bits, bytes),
  proof_ensure: result => metadata_length_post(bits, bytes, result),
} {
  if bytes == 0 {
    Some(0)
  } else if bytes > 1 && @proof_bits.shr(bits, 8 * (bytes - 1)) == 0 {
    None
  } else {
    Some(bits + 1)
  }
}
