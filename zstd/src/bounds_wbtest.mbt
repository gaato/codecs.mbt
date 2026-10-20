///|
/// The most `memory_usage` may report: the window limit, one compressed
/// block and its literals.
fn memory_bound(max_window_bits : Int32) -> Int32 {
  (1 << max_window_bits) + 2 * MAX_BLOCK_SIZE
}

///|
/// Checks the limits RESOURCE_BOUNDS.md states, after a step that had
/// `room` bytes of output.
fn check_bounds(d : Decoder, room : Int32) -> Unit raise {
  // Output slices.
  assert_true(d.last_produced() <= room)
  // Header bytes: at most a 14-byte frame header.
  assert_true(d.hdr_len <= 14 && d.hdr.length() == 14)
  // The window: at most the frame's Window_Size, within the limit.
  assert_true(d.ring_max <= 1 << d.max_window_bits)
  assert_true(d.ring.length() <= d.ring_max || d.new_frame)
  assert_true(d.pending <= d.ring.length())
  // One compressed block and its literals.
  assert_true(d.block.length() <= MAX_BLOCK_SIZE)
  assert_true(d.literals.length() <= MAX_BLOCK_SIZE)
  // What `memory_usage` reports, within the window and two blocks.
  assert_eq(
    d.memory_usage(),
    d.ring.length() + d.block.length() + d.literals.length(),
  )
  assert_true(d.memory_usage() <= memory_bound(d.max_window_bits))
  // Fixed tables.
  assert_true(d.ll_store.symbol.length() == 512)
  assert_true(d.ml_store.symbol.length() == 512)
  assert_true(d.of_store.symbol.length() == 256)
  assert_true(d.huffman.symbol.length() == 2048)
}

///|
test "output slices, the window and the block buffers stay within their bounds" {
  for v in vectors {
    guard v.size <= 300000 else { continue }
    let got = drive(
      Decoder(max_window_bits=v.window_bits),
      v.input(),
      next_in=() => 1,
      next_out=() => 997,
      check=check_bounds,
    )
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "the window is at most Window_Size and grows only with output" {
  let window = (name : String) => {
    let v = vector(name)
    let decoder = Decoder(max_window_bits=v.window_bits)
    let mut largest = 0
    let got = drive(
      decoder,
      v.input(),
      next_in=() => 4096,
      next_out=() => 65536,
      check=(d, room) => {
        check_bounds(d, room)
        largest = largest.max(d.ring.length())
      },
    )
    assert_eq(got.length(), v.size)
    (largest, decoder.ring_max)
  }
  // 10 KB under a declared 128 MiB window: the window stops at 16 KiB.
  debug_inspect(window("gen/window27_declared"), content="(16384, 134217728)")
  // A 1 KiB window wraps instead of growing.
  debug_inspect(window("gen/window10_text"), content="(1024, 1024)")
  // A single-segment frame's window is its content size.
  debug_inspect(window("gen/text_200"), content="(200, 200)")
  // 5 MiB of output under an 8 MiB window.
  debug_inspect(window("gen/window23_far"), content="(8388608, 8388608)")
}

///|
test "a compressed block waits until earlier output is handed out" {
  // Output one byte at a time: a compressed block is decoded only once the
  // window holds no pending bytes, so pending output stays within a block.
  for name in ["gen/text_level19", "gen/mixed_flushed", "gen/window10_text"] {
    let v = vector(name)
    let mut most = 0
    let got = drive(
      Decoder(max_window_bits=v.window_bits),
      v.input(),
      next_in=() => 100000,
      next_out=() => 1,
      check=(d, room) => {
        check_bounds(d, room)
        most = most.max(d.pending)
      },
    )
    assert_eq(@checksum.sha256(got), v.sha256, msg=name)
    assert_true(most <= MAX_BLOCK_SIZE, msg=name)
  }
}

///|
test "memory_usage stays within the window limit and two blocks" {
  // Every vector, at the smallest window it needs, checked after every step.
  for v in vectors {
    let decoder = Decoder(max_window_bits=v.window_bits)
    let mut peak = 0
    let got = drive(
      decoder,
      v.input(),
      next_in=() => 4096,
      next_out=() => 65536,
      check=(d, room) => {
        check_bounds(d, room)
        peak = peak.max(d.memory_usage())
      },
    )
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
    assert_true(peak <= memory_bound(v.window_bits), msg=v.name)
  }
  // 5 MiB of output under an 8 MiB window, and a 128 KiB block.
  let v = vector("gen/window23_far")
  let decoder = Decoder(max_window_bits=v.window_bits)
  let mut peak = 0
  let _ = drive(
    decoder,
    v.input(),
    next_in=() => 1 << 20,
    next_out=() => 1 << 20,
    check=(d, _) => peak = peak.max(d.memory_usage()),
  )
  inspect(peak, content="8395131")
  inspect(memory_bound(v.window_bits), content="8650752")
}

///|
test "memory_usage drops when a frame needs a smaller window" {
  // 5,000 bytes under a 128 KiB window, then one byte under a 1 KiB one.
  let large = frame(plain(b'\x38'), block(1, [b'a'], size=5000))
  let small = frame(plain(b'\x00'), block(0, [b'b']))
  let decoder = Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  inspect(decoder.memory_usage(), content="0")
  debug_inspect(
    decoder.step_into(large, out, end=false),
    content="NeedMoreInput",
  )
  inspect(decoder.memory_usage(), content="8192")
  debug_inspect(decoder.step_into(small, out, end=true), content="Done")
  inspect(decoder.memory_usage(), content="1024")
  decoder.reset()
  inspect(decoder.memory_usage(), content="0")
}
