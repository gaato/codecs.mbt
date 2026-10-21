///|
test "known digests" {
  inspect(
    @fixtures.sha256(b""),
    content="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
  )
  inspect(
    @fixtures.sha256(b"abc"),
    content="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
  )
  let long = Bytes::make(1000, b'a')
  inspect(
    @fixtures.sha256(long),
    content="41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3",
  )
}
