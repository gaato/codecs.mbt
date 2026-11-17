///|
priv struct Deflate64Vector {
  name : String
  size : Int32
  sha256 : String
  stream_sha256 : String
  compressed : String
}

///|
test "Deflate64 reproduces the SHA-256 of 7-Zip method 9 members under every split" {
  for v in vectors {
    let stream = @fixtures.decode64(v.compressed)
    assert_eq(@fixtures.sha256(stream), v.stream_sha256)
    let rng = @fixtures.Rng::new(1952)
    for shape in [0, 1, 2] {
      let (got, consumed) = @fixtures.drive(
        Decoder(),
        stream,
        next_in=() => {
          match shape {
            0 => 1 << 20
            1 => 1
            _ => 1 + rng.below(113)
          }
        },
        next_out=() => if shape == 0 { 1 << 17 } else { 1 + rng.below(257) },
      )
      assert_eq(got.length(), v.size, msg=v.name)
      assert_eq(@fixtures.sha256(got), v.sha256, msg=v.name)
      assert_eq(consumed, stream.length())
    }
  }
}
