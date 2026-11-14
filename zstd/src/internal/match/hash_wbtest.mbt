///|
/// `hash_bytes` (on JS in 32-bit halves) against ZSTD_hash4..8 on 64-bit
/// integers, for every width and many logs.
#cfg(not(any(target="native", target="wasm")))
test "hash_bytes agrees with the 64-bit hashes" {
  let data = FixedArray::makei(300, i => {
    ((i.reinterpret_as_uint() * 2654435761U) >> 13).to_byte()
  })
  for width in 4..<=8 {
    for log in [8, 12, 17, 22, 24] {
      for p in 0..<280 {
        let mut word = 0UL
        for i in 0..<width {
          word = word | (data[p + i].to_uint64() << (8 * i))
        }
        let expected = if width == 4 {
          ((word.to_uint() * 2654435761U) >> (32 - log)).reinterpret_as_int()
        } else {
          let prime = match width {
            5 => 889523592379UL
            6 => 227718039650203UL
            7 => 58295818150454627UL
            _ => 0xcf1bbcdcb7a56463UL
          }
          (((word << (64 - width * 8)) * prime) >> (64 - log)).to_int()
        }
        assert_eq(hash_bytes(data, p, width, log), expected)
      }
    }
  }
}
