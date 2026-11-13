///|
test "large mixed frames preserve bytes across several window slides" {
  let input = @seqcases.sliding_input()
  let pins = []
  for level in [1, 3, 5, 12] {
    let mut previous_start = 0
    let mut slides = 0
    let stream = encode_drive(
      Encoder(level~),
      input,
      next_in=() => 131071,
      next_out=() => 65536,
      check=(e, room) => {
        check_encoder_bounds(e, room)
        let start = e.matcher.history().block_start()
        if start < previous_start {
          slides += 1
        }
        previous_start = start
      },
    )
    assert_true(slides >= (if level == 12 { 1 } else { 2 }))
    assert_eq(decompress(stream), input)
    pins.push(@checksum.sha256(stream))
  }
  // Established with the original per-block sliding implementation.
  inspect(
    pins.join("\n"),
    content=(
      #|441f5a400043c1df4f5d1b97934fe9eda7729d67d811fa63cf477b6375afa65c
      #|dd7e68ce686ac6f077107ef369274f63925b55963dcba0545c22ee7bf25cd9d2
      #|191f7f620f0e21c0ffa3c4f931187857e684b7db8d61436bf3908ef6d84fa83e
      #|1d80f5e73bae739f4745d4e74cb476ff6cee0506b8ab5cd711fd75af4fdf9cc8
    ),
  )
}

///|
test "identical flush positions preserve output under every input split" {
  let input = sample_text(Rng::new(8878), 32768)
  for level in 1..<=12 {
    let whole = encode_drive(
      Encoder(level~),
      input,
      next_in=() => 4096,
      next_out=() => 65536,
      flush=p => p % 4096 == 0,
    )
    for split in [1, 16, 1024] {
      let divided = encode_drive(
        Encoder(level~),
        input,
        next_in=() => split,
        next_out=() => 37,
        flush=p => p % 4096 == 0,
      )
      assert_eq(divided, whole)
    }
  }
}
