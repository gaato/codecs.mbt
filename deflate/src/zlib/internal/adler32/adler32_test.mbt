///|
/// Adler-32 as RFC 1950 section 9 writes it, a byte at a time.
fn reference(data : Bytes) -> UInt32 {
  let mut a = 1U
  let mut b = 0U
  for byte in data {
    a = (a + byte.to_uint()) % 65521
    b = (b + a) % 65521
  }
  (b << 16) | a
}

///|
test "known values" {
  inspect(@adler32.of_bytes(b""), content="1")
  // The example of Wikipedia's article on Adler-32.
  inspect(@adler32.of_bytes(b"Wikipedia"), content="300286872")
}

///|
test "equal to the reference, whole and in pieces, past the reduction interval" {
  let data = Bytes::makei(20000, i => (255 - i % 7).to_byte())
  for n in [0, 1, 5551, 5552, 5553, 11104, 20000] {
    let part = data[:n].to_owned()
    assert_eq(@adler32.of_bytes(part), reference(part), msg="\{n}")
  }
  let mut adler = @adler32.INITIAL
  let array = data.to_array()
  for start = 0; start < array.length(); start = start + 777 {
    adler = @adler32.update(
      adler,
      array[start:(start + 777).min(array.length())],
    )
  }
  assert_eq(adler, reference(data))
}

///|
test "all 0xff bytes, the largest sums" {
  let data = Bytes::make(100000, b'\xff')
  assert_eq(@adler32.of_bytes(data), reference(data))
}
