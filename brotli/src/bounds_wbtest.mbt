///|
/// The largest distance alphabet: NDIRECT 120, NPOSTFIX 3.
const MAX_DISTANCE_ALPHABET : Int32 = 16 + 120 + (48 << 3)

///|
/// Checks the limits RESOURCE_BOUNDS.md states, after a step that had
/// `room` bytes of output.
fn check_bounds(d : Decoder, room : Int32) -> Unit raise {
  // Output slices.
  assert_true(d.last_produced() <= room)
  // The unfinished unit: at most 63 bits of input.
  assert_true(d.stash.length() - d.stash_pos <= 8)
  // The window.
  assert_true(d.ring_max <= 1 << d.max_window_bits)
  assert_true(d.ring.length() <= d.ring_max)
  assert_true(d.pending <= d.ring.length())
  // Prefix code tables: in this meta-block, then over the stream.
  let (lit, cmd, dist) = (d.lit_trees, d.cmd_trees, d.dist_trees)
  assert_true(lit.used <= d.lit_trees_count * max_table_size(NUM_LITERALS))
  assert_true(cmd.used <= d.num_types[1] * max_table_size(MAX_ALPHABET))
  assert_true(
    dist.used <=
    d.dist_trees_count * max_table_size(16 + d.ndirect + (48 << d.npostfix)),
  )
  assert_true(lit.pool.length() <= 256 * max_table_size(NUM_LITERALS))
  assert_true(cmd.pool.length() <= 256 * max_table_size(MAX_ALPHABET))
  assert_true(dist.pool.length() <= 256 * max_table_size(MAX_DISTANCE_ALPHABET))
  for c in 0..<3 {
    assert_true(d.type_codes[c].pool.length() <= max_table_size(258))
    assert_true(
      d.count_codes[c].pool.length() <= max_table_size(NUM_BLOCK_COUNT_CODES),
    )
  }
  assert_true(d.map_code.pool.length() <= max_table_size(256 + 16))
  assert_true(d.code.cl_code.pool.length() <= max_table_size(18))
}

///|
test "output slices, the stash and the tables stay within their bounds" {
  for v in vectors {
    guard v.size <= 300000 else { continue }
    let got = drive(
      Decoder(),
      v.input(),
      next_in=() => 1,
      next_out=() => 997,
      check=check_bounds,
    )
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "the window is at most 1 << WBITS and grows only with output" {
  let window = (name : String) => {
    let v = vectors[vectors.search_by(v => v.name == name).unwrap()]
    let decoder = Decoder()
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
  // A one-byte stream with a 4 MiB window allocates the first 1 KiB only.
  debug_inspect(window("x.compressed"), content="(1024, 4194304)")
  // A 1 KiB window wraps instead of growing.
  debug_inspect(window("gen/window10"), content="(1024, 1024)")
  // 5 MiB of output under a 16 MiB window: the window stops at 8 MiB.
  debug_inspect(
    window("gen/window24_far"),
    content=(
      #|(8388608, 16777216)
    ),
  )
}

///|
/// The most compressed bytes that wait in an encoder: the input of one
/// meta-block (as an uncompressed meta-block) and its header, or a
/// compressed attempt stopped one command past that.
const MAX_ENCODER_PENDING : Int32 = BLOCK_SIZE + 64

///|
/// Checks the encoder's limits RESOURCE_BOUNDS.md states, after a step
/// that had `room` bytes of output.
fn check_encoder_bounds(e : Encoder, room : Int32) -> Unit raise {
  assert_true(e.last_produced() <= room)
  // The input buffer: the window, then at most a meta-block not encoded.
  assert_true(e.data.length() <= e.data_max)
  assert_true(
    e.data_max <=
    (1 << e.window_bits) -
    16 +
    (1 << (e.window_bits - 2)).max(BLOCK_SIZE) +
    BLOCK_SIZE,
  )
  assert_true(e.block_start <= e.data_len)
  assert_true(e.data_len - e.block_start <= BLOCK_SIZE)
  // Output waiting for the caller, and a meta-block's commands.
  assert_true(e.writer.len <= MAX_ENCODER_PENDING)
  assert_true(e.writer.buf.length() <= 2 * MAX_ENCODER_PENDING)
  assert_true(e.meta_block.count <= MAX_COMMANDS)
  // The hash table.
  assert_eq(e.matcher.capacity(), 4 << e.window_bits.min(15))
}

///|
test "the encoder's input buffer grows only with input, then slides" {
  let rng = Rng::new(24)
  let input = sample_text(rng, 300000) +
    sample_random(rng, 200000) +
    sample_text(rng, 600000)
  let largest = (window_bits : Int32, input : Bytes) => {
    let encoder = Encoder(window_bits~)
    let mut largest = 0
    let mut taken = 0
    let mut slides = 0
    let stream = encode_drive(
      encoder,
      input,
      next_in=() => 5000,
      next_out=() => 65536,
      check=(e, room) => {
        check_encoder_bounds(e, room)
        taken += e.last_consumed()
        // Doubling from 1 KiB: at most twice the input so far.
        assert_true(e.data.length() <= (2 * taken).max(1024))
        if e.data_len < largest && e.data.length() == e.data_max {
          slides += 1
        }
        largest = largest.max(e.data_len)
      },
    )
    assert_true(decompress(stream, max_window_bits=window_bits) == input)
    (encoder.data.length(), encoder.data_max, slides > 0)
  }
  // A few bytes take the first 1 KiB.
  debug_inspect(largest(22, b"tiny"), content="(1024, 5308400, false)")
  // A 1 KiB window: the buffer stops at the window and two meta-blocks,
  // then slides.
  debug_inspect(largest(10, input), content="(132080, 132080, true)")
  // A 4 MiB window over 1.1 MB: the buffer only grows.
  debug_inspect(largest(22, input), content="(2097152, 5308400, false)")
}

///|
test "the encoder's waiting output is at most a meta-block" {
  let rng = Rng::new(25)
  let input = sample_random(rng, 200000) + sample_text(rng, 200000)
  let encoder = Encoder()
  let mut largest = 0
  let stream = encode_drive(
    encoder,
    input,
    next_in=() => 1 << 20,
    next_out=() => 1000,
    check=(e, room) => {
      check_encoder_bounds(e, room)
      largest = largest.max(e.writer.len)
    },
  )
  assert_true(decompress(stream) == input)
  // Random input comes out as uncompressed meta-blocks, the largest.
  assert_true(largest > BLOCK_SIZE)
  assert_true(largest <= MAX_ENCODER_PENDING)
}
