///|
test "hash4 reads four bytes little-endian; match_length stops at a difference or the limit" {
  let data : FixedArray[Byte] = [b'a', b'b', b'c', b'd', b'a', b'b', b'c', b'x']
  // 0x64636261 * 0x1e35a7bd, top 16 bits.
  inspect(@lz77.hash4(data, 0, 16), content="44705")
  assert_eq(
    (@lz77.hash4(data, 0, 32).reinterpret_as_uint() >> 16).reinterpret_as_int(),
    @lz77.hash4(data, 0, 16),
  )
  assert_true(@lz77.hash4(data, 4, 16) != @lz77.hash4(data, 0, 16))
  inspect(@lz77.match_length(data, 0, 4, 4), content="3")
  inspect(@lz77.match_length(data, 0, 4, 2), content="2")
}
