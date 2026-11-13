///|
test "matches and hashes end at the last valid bytes on every target" {
  let pins = []
  for level in [1, 3, 5, 12] {
    let frames = Buffer()
    for (name, input) in @seqcases.boundary_inputs() {
      let frame = compress(input, level~)
      assert_true(decompress(frame) == input, msg="\{name} level \{level}")
      frames.write_bytes(frame)
      let whole = encode_drive(Encoder(level~), input, next_in=() => 1 << 20, next_out=() => {
        1 << 20
      })
      assert_true(decompress(whole) == input, msg="\{name} unsized \{level}")
      frames.write_bytes(whole)
      // Small inputs also cross the 8/16-byte reads one input byte at a
      // time; larger ones split immediately before a cutter boundary.
      let split = encode_drive(
        Encoder(level~),
        input,
        next_in=() => if input.length() <= 48 { 1 } else { 131071 },
        next_out=() => 37,
      )
      assert_true(split == whole, msg="\{name} split \{level}")
    }
    pins.push(@checksum.sha256(frames.to_bytes()))
  }
  // Established with the checked byte-at-a-time implementation before
  // replacing the hash and length loops, then shared by all four targets.
  inspect(
    pins.join("\n"),
    content=(
      #|89f5f0307d804f2f5cbd4d74ef3b154e3ad783659b1ddddfa0cd12119210d690
      #|6342a3ff3ad2764c1253c519f250680220db7d35127045a03454b7a8e4f28156
      #|ec856b272d8abeda9755dd80305104749efb617f554ae6664f9e40cc05692aa8
      #|e3b99fa77e4940c166892ca0e74a5204cf93fcaf3337c33e2429bcc0308aa07c
    ),
  )
}

///|
test "small window frames decode across hash completion and evicted replays" {
  for case in @seqcases.window_cases() {
    assert_true(decompress(case.frame) == case.input, msg=case.name)
  }
}
