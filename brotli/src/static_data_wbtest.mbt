///|
test "the dictionary matches RFC 7932 Appendix A and google/brotli" {
  inspect(dictionary.length(), content="122784")
  inspect(@checksum.crc32(dictionary), content="1362545412")
  inspect(
    @checksum.sha256(dictionary),
    content="20e42eb1b511c21806d4d227d07e5dd06877d8ce7b3a817f378f313653f35c70",
  )
  // DOFFSET ends where the dictionary does.
  inspect(
    dictionary_offsets[24] + (24 << dictionary_size_bits[24]),
    content="122784",
  )
}

///|
test "the context lookup tables match RFC 7932 section 7.1" {
  let crc = (table : FixedArray[Byte]) => {
    @checksum.crc32(Bytes::from_array(table[:]))
  }
  inspect(crc(lut0), content="2391928759")
  inspect(crc(lut1), content="3491377908")
  inspect(crc(lut2), content="232235222")
}

///|
test "the transforms match RFC 7932 Appendix B" {
  // Appendix B serializes each transform as prefix, 0, type, suffix, 0, with
  // types numbered 0 Identity, 1 FermentFirst, 2 FermentAll, 3-11
  // OmitFirst1-9, 12-20 OmitLast1-9.
  let rfc_type = (kind : Int32) => {
    match kind {
      0 => 0
      1..<=9 => kind + 11
      10 => 1
      11 => 2
      _ => kind - 9
    }
  }
  let out = Buffer()
  for i in 0..<NUM_TRANSFORMS {
    out.write_bytes(transform_prefixes[i])
    out.write_byte(b'\x00')
    out.write_byte(rfc_type(transform_types[i].to_int()).to_byte())
    out.write_bytes(transform_suffixes[i])
    out.write_byte(b'\x00')
  }
  let bytes = out.to_bytes()
  inspect(bytes.length(), content="648")
  inspect(@checksum.crc32(bytes), content="1033265025")
}
