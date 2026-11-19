// Generated from parts/copy16/copy16_test.mbt by scripts/gen_parts.mbtx: edit it there, not here.

///|
test "copy16 copies unaligned, adjacent ranges up to the array end" {
  let buf = FixedArray::makei(33, i => i.to_byte())
  @copy16.copy16(buf, 17, 1)
  assert_eq(buf[0], b'\x00')
  for i in 1..<17 {
    assert_eq(buf[i], i.to_byte())
    assert_eq(buf[i + 16], i.to_byte())
  }
}

///|
test "copy16_from_view uses the view's origin and writes exactly 16 bytes" {
  let input = b"xx?abcdefghijklmnop!"
  let buf = FixedArray::make(18, b'.')
  @copy16.copy16_from_view(buf, 1, input[2:19], 1)
  assert_eq(Bytes::from_array(buf[:]), b".abcdefghijklmnop.")
}
