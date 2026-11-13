///|
/// Inputs shared by the encoder's boundary pins and the external decoders.
/// Matches straddle a 1 KiB window-size boundary and the 128 KiB cutter;
/// their ends leave 1..16 bytes, or reach the very last valid byte.
pub fn boundary_inputs() -> Array[(String, Bytes)] {
  let inputs = []
  for n in 1..<=48 {
    inputs.push(("tiny\{n}", Bytes::makei(n, i => (i % 7).to_byte())))
  }
  for boundary in [1024, 131072] {
    for tail in 1..<=16 {
      let mut seed = 8878U
      let data = FixedArray::makei(boundary + tail, _ => {
        seed = seed * 1664525 + 1013904223
        (seed >> 24).to_byte()
      })
      // Each length ends before the boundary with exactly `tail` bytes
      // of lookahead. Distinct sources avoid accidental longer matches.
      for j, len in [7, 8, 9, 15, 16, 17, 31, 32, 33] {
        let p = boundary - tail - (9 - j) * 64
        for i in 0..<len {
          data[p + i] = data[32 + j * 37 + i]
        }
        data[p + len] = data[32 + j * 37 + len] ^ b'\xff'
      }
      // A match crosses the cutter, leaving only tail valid input bytes
      // in the final block. No padding belongs to the input.
      for i in 0..<(17 + tail) {
        data[boundary - 17 + i] = data[400 + i]
      }
      inputs.push(("boundary\{boundary}-tail\{tail}", Bytes::from_array(data)))
    }
  }
  inputs
}

///|
/// Mixed bytes beyond twice the largest encoder window. Replays around
/// 4/8 MiB exercise retained and expired sources in production rows.
pub fn sliding_input() -> Bytes {
  let mut seed = 8878U
  let tile = Bytes::makei(1 << 18, i => {
    seed = seed * 1664525 + 1013904223
    if i % 4096 < 2048 {
      (i % 251).to_byte()
    } else {
      (seed >> 24).to_byte()
    }
  })
  Bytes::makei(12 * (1 << 20) + 37, i => {
    if i % 257 == 0 {
      tile[i % tile.length()] ^ (i >> 18).to_byte()
    } else {
      tile[i % tile.length()]
    }
  })
}

///|
/// Frames from all three finders with a 1 KiB window. Short blocks finish
/// hashes across boundaries, slide history, and replay either evicted or
/// surviving bytes. The same frames go to gaato, zstd -d and Node.
pub fn window_cases() -> Array[Case] {
  let cases = []
  for level in [1, 3, 5, 6, 12] {
    for tail in 1..<=16 {
      for offset in [0, 100] {
        let mut seed = 8878U
        let original = FixedArray::makei(1024, _ => {
          seed = seed * 1664525 + 1013904223
          (seed >> 24).to_byte()
        })
        let short = FixedArray::makei(17 + tail, i => original[i])
        let unrelated = FixedArray::makei(64, _ => {
          seed = seed * 1664525 + 1013904223
          (seed >> 24).to_byte()
        })
        let replay = FixedArray::makei(64, i => original[offset + i])
        let chunks = [original, short, unrelated, replay]
        // Repeating the cycle exceeds window + slack + block several
        // times even for the largest slack candidate. Each cycle includes
        // short lookahead, unrelated bytes and an expired/surviving replay.
        for _ in 0..<8 {
          for data in [original, short, unrelated, replay] {
            chunks.push(data)
          }
        }
        cases.push(
          window_frame(
            "window1024-l\{level}-tail\{tail}-replay\{offset}",
            level,
            chunks,
          ),
        )
      }
    }
  }
  // Identical input chunks to history_wbtest's repeated physical-cut replay.
  for level in [1, 3, 5, 6, 12] {
    for offset in [2047, 2049] {
      let mut seed = 8878U
      let chunks = []
      for cycle in 0..<6 {
        let original = FixedArray::makei(3072, _ => {
          seed = seed * 1664525 + 1013904223
          (seed >> 24).to_byte()
        })
        for index in (if cycle == 0 { 0 } else { 2 })..<3 {
          chunks.push(FixedArray::makei(1024, i => original[index * 1024 + i]))
        }
        chunks.push(FixedArray::makei(64, i => original[offset + i]))
        chunks.push(FixedArray::make(960, b'!'))
      }
      cases.push(
        window_frame("physical-cuts-l\{level}-replay\{offset}", level, chunks),
      )
    }
  }
  cases
}

///|
fn window_frame(
  name : String,
  level : Int32,
  chunks : Array[FixedArray[Byte]],
) -> Case {
  let fast = @match.Fast(
    hash_log=12,
    min_match=7,
    target_length=0,
    window_log=10,
  )
  let dfast = @match.Dfast(
    hash_log=12,
    chain_log=12,
    min_match=4,
    window_log=10,
  )
  let chain = @match.Lazy(
    hash_log=12,
    chain_log=10,
    min_match=5,
    search_log=4,
    depth=if level == 5 { 0 } else if level == 6 { 1 } else { 2 },
    window_log=10,
  )
  let plain = Buffer()
  let out = @bits.BitPacker()
  out.write(32, 0xfd2fb528U.reinterpret_as_int())
  out.write(8, 0) // no checksum or content size
  out.write(8, 0) // windowLog 10
  let writer = @seqenc.Writer()
  let block = @seqenc.Block()
  let modes = []
  for index, data in chunks {
    if level == 1 {
      fast.find(data, data.length(), writer.repeats, block)
    } else if level == 3 {
      dfast.find(data, data.length(), writer.repeats, block)
    } else {
      chain.find(data, data.length(), writer.repeats, block)
    }
    plain.write_bytes(Bytes::from_array(data))
    let last = index == chunks.length() - 1
    // Incompressible 1 KiB cannot have a compressed body larger
    // than its window. Raw blocks preserve the writer's state.
    if block.count == 0 {
      out.write(24, (data.length() << 3) | (if last { 1 } else { 0 }))
      out.write_bytes(data, 0, data.length())
    } else {
      write_sequence_block(out, writer, block, last)
    }
    modes.push(writer.modes())
  }
  let bytes = FixedArray::make(out.pending(), b'\x00')
  out.drain_into(bytes, 0) |> ignore
  { name, input: plain.to_bytes(), frame: Bytes::from_array(bytes), modes, }
}
