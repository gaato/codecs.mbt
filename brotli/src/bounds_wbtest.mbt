///|
test "a new decoder holds exactly its fixed memory" {
  for bits in [10, 16, 24] {
    assert_eq(
      Decoder(max_window_bits=bits).memory_usage(),
      DECODER_FIXED_MEMORY,
    )
  }
}

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
      d.count_codes[c].pool.length() <=
      max_table_size(@rules.NUM_BLOCK_COUNT_CODES),
    )
  }
  assert_true(d.map_code.pool.length() <= max_table_size(256 + 16))
  assert_true(d.code.cl_code.pool.length() <= max_table_size(18))
  // Everything sized by the stream.
  assert_true(
    d.memory_usage() <=
    decoder_memory_bound(max_window_bits=d.max_window_bits).to_int(),
  )
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
  assert_true(e.writer.buffered() <= MAX_ENCODER_PENDING)
  assert_true(e.writer.capacity() <= 2 * MAX_ENCODER_PENDING)
  assert_true(e.meta_block.count <= MAX_COMMANDS)
  // The hash table.
  assert_eq(e.matcher.capacity(), 4 << e.window_bits.min(15))
  // Everything sized by the stream.
  assert_true(
    e.memory_usage() <= encoder_memory_bound(window_bits=e.window_bits).to_int(),
  )
}

///|
test "a new encoder holds exactly its fixed memory" {
  for w in 10..<=24 {
    assert_eq(Encoder(window_bits=w).memory_usage(), encoder_fixed_memory(w))
  }
}

///|
/// The WBITS a stream declares (section 9.1).
fn stream_wbits(stream : BytesView) -> Int32 {
  let b = stream[0].to_int() |
    (if stream.length() > 1 { stream[1].to_int() << 8 } else { 0 })
  if (b & 1) == 0 {
    16
  } else if ((b >> 1) & 7) != 0 {
    17 + ((b >> 1) & 7)
  } else if ((b >> 4) & 7) != 0 {
    8 + ((b >> 4) & 7)
  } else {
    17
  }
}

///|
test "memory_usage stays within its bound after every step" {
  // The figures RESOURCE_BOUNDS.md gives.
  inspect(max_decoder_table_bytes(), content="1343596")
  inspect(encoder_memory_bound(window_bits=22).to_int(), content="6315516")
  inspect(encoder_memory_bound(window_bits=24).to_int(), content="22044156")
  let rng = Rng::new(2026)
  let mut largest = 0
  for v in vectors {
    guard v.size <= 300000 else { continue }
    let input = v.input()
    guard input.length() > 0 else { continue }
    // The tightest limit the stream passes, and the widest.
    for bits in [stream_wbits(input), 24] {
      let decoder = Decoder(max_window_bits=bits)
      let got = drive(
        decoder,
        input,
        next_in=() => 1 + rng.below(700),
        next_out=() => 1 + rng.below(9000),
        check=(d, room) => {
          check_bounds(d, room)
          largest = largest.max(d.memory_usage())
        },
      )
      assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
    }
  }
  // Some stream used most of its window and tables.
  assert_true(largest > 1 << 16)
  let input = sample_text(rng, 300000) + sample_random(rng, 100000)
  for window_bits in [10, 16, 22] {
    let encoder = Encoder(window_bits~)
    let stream = encode_drive(
      encoder,
      input,
      next_in=() => 1 + rng.below(20000),
      next_out=() => 1 + rng.below(5000),
      flush=_ => rng.below(8) == 0,
      check=check_encoder_bounds,
    )
    assert_true(decompress(stream) == input)
    // `reset` releases the input buffer.
    encoder.reset()
    assert_true(
      encoder.memory_usage() <=
      2 * MAX_ENCODER_PENDING + encoder_fixed_memory(encoder.window_bits),
    )
  }
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
      largest = largest.max(e.writer.buffered())
    },
  )
  assert_true(decompress(stream) == input)
  // Random input comes out as uncompressed meta-blocks, the largest.
  assert_true(largest > BLOCK_SIZE)
  assert_true(largest <= MAX_ENCODER_PENDING)
}

///|
test "metadata meta-blocks are skipped as they arrive, none of them held" {
  // WBITS 16; a metadata meta-block (MNIBBLES 0, MSKIPBYTES 3) of 1 MiB;
  // then the last, empty meta-block.
  let size = 1 << 20
  let header = BitWriter::new()
    .bits(1, 0)
    .bits(1, 0)
    .bits(2, 3)
    .bits(1, 0)
    .bits(2, 3)
    .bits(24, size - 1)
    .finish()
  let stream = Buffer()
  stream.write_bytes(header)
  stream.write_bytes(Bytes::make(size, b'\x5a'))
  stream.write_byte(b'\x03')
  let stream = stream.to_bytes()
  let decoder = Decoder(max_window_bits=16)
  let got = drive(decoder, stream, next_in=() => 4096, next_out=() => 1024, check=(
    d,
    room,
  ) => {
    check_bounds(d, room)
    // The window is not allocated for bytes that are not output.
    assert_eq(d.memory_usage(), DECODER_FIXED_MEMORY)
  })
  assert_eq(got.length(), 0)
}

///|
test "with a dictionary, the encoder's memory stays within its bound after every step" {
  let rng = Rng::new(9841)
  let content = sample_random(rng, 100000)
  let dict = Dictionary(content)
  let input = Buffer()
  while input.length() < 300000 {
    let at = rng.below(99000)
    input.write_bytesview(content[at:at + 1000])
    input.write_bytes(sample_random(rng, 50))
  }
  let input = input.to_bytes()
  for w in [10, 16, 22] {
    let encoder = Encoder(window_bits=w, dictionary=dict)
    let stream = encode_drive(
      encoder,
      input,
      next_in=() => 1 + rng.below(20000),
      next_out=() => 1 + rng.below(5000),
      flush=_ => rng.below(8) == 0,
      check=check_encoder_bounds,
    )
    assert_true(decompress(stream, dictionary=dict) == input)
    // The index is the dictionary's, counted by it, not by the encoder.
    assert_true(dict.memory_usage() > 0)
    assert_true(
      encoder.memory_usage() <= encoder_memory_bound(window_bits=w).to_int(),
    )
  }
}

///|
test "the public bounds: compress output, and flushed streams" {
  let rng = Rng::new(11)
  for n in [0, 1, 1000, 65536, 65537, 300000] {
    let input = sample_random(rng, n)
    for w in [10, 16, 22, 24] {
      let stream = compress(input, window_bits=w)
      assert_true(stream.length().to_int64() <= compress_bound(n.to_int64()))
    }
    // A flush every 1,000 bytes: 7 bytes more for each.
    let flushes = n / 1000
    let flushed = encode_drive(
      Encoder(),
      input,
      next_in=() => 1000,
      next_out=() => 1 << 16,
      flush=_ => true,
    )
    assert_true(
      flushed.length().to_int64() <=
      compress_bound(n.to_int64()) + 7L * flushes.to_int64(),
    )
  }
  assert_eq(compress_bound(-3L), compress_bound(0L))
  assert_eq(compress_bound(0x7FFFFFFFFFFFFFFFL), 0x7FFFFFFFFFFFFFFFL)
  assert_eq(
    decoder_memory_bound(max_window_bits=30),
    decoder_memory_bound(max_window_bits=24),
  )
  assert_eq(encoder_memory_bound(), 6315516L)
}
