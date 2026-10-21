///|
test "the arithmetic overflows at run time" {
  assert_true(@machine_int.add_u32(0xFFFFFFFF, 1) < 0xFFFFFFFF)
  assert_true(@machine_int.double(0x40000000) < 0x40000000)
}
