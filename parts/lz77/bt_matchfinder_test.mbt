///|
// Also mirrored by scripts/reference/libdeflate/gen_vectors.mbtx. The oracle
// vectors pin the input digest as well as the match-list digest.
fn bt_oracle_input(kind : String, size : Int32) -> FixedArray[Byte] {
  let text = b"The quick brown fox jumps over the lazy dog. Binary trees find repeated prefixes.\n"
  let data = FixedArray::make(size, b'\x00')
  let mut state = 9U
  for i in 0..<size {
    state = (state * 1103515245U + 12345U) & 0x7fffffffU
    let random = ((state >> 16) & 255U).reinterpret_as_int()
    data[i] = match kind {
      "text" => text[i % text.length()]
      "binary" =>
        if i >= 512 && i % 1024 < 400 {
          data[i - 512]
        } else {
          random.to_byte()
        }
      "runs" => if i % 4096 < 3500 { b'a' } else { (random & 3).to_byte() }
      "window" => {
        let distance = match i / 2048 % 4 {
          0 => 32767
          1 => 32768
          2 => 32769
          _ => 70001
        }
        if i >= distance && i % 2048 < 1024 {
          data[i - distance]
        } else {
          (random & 3).to_byte()
        }
      }
      _ => abort("unknown bt oracle input")
    }
  }
  data
}

///|
fn bt_digest_word(hash : UInt64, word : Int32) -> UInt64 {
  let mut hash = hash
  for shift in [0, 8, 16, 24] {
    hash = (hash ^ ((word.reinterpret_as_uint() >> shift) & 255U).to_uint64()) *
      1099511628211UL
  }
  hash
}

///|
fn bt_input_digest(data : FixedArray[Byte]) -> UInt64 {
  let mut hash = 14695981039346656037UL
  for byte in data {
    hash = (hash ^ byte.to_uint64()) * 1099511628211UL
  }
  hash
}

///|
fn bt_match_digest(
  data : FixedArray[Byte],
  depth : Int32,
  nice : Int32,
  mode : String,
) -> UInt64 {
  let finder = @lz77.BtMatchfinder()
  let matches = FixedArray::make(2 * (nice - 2), 0)
  let mut hash = 14695981039346656037UL
  let mut skip = 0
  for pos in 0..<data.length() {
    let max_len = (data.length() - pos).min(258)
    let nice_len = nice.min(max_len)
    let mut kind = if skip > 0 { 1 } else { 0 }
    let count = if max_len < 5 {
      kind = 2
      0
    } else if skip > 0 {
      finder.skip_byte(data, pos, nice_len, depth)
      0
    } else {
      finder.get_matches(data, pos, max_len, nice_len, depth, matches)
    }
    hash = bt_digest_word(hash, pos)
    hash = bt_digest_word(hash, kind)
    hash = bt_digest_word(hash, count)
    for i in 0..<(2 * count) {
      hash = bt_digest_word(hash, matches[i])
    }
    if skip > 0 {
      skip -= 1
    } else if mode == "level10" &&
      count > 0 &&
      matches[2 * (count - 1)] >= nice_len {
      skip = matches[2 * (count - 1)] - 1
    }
  }
  hash
}

///|
fn bt_validate(
  data : FixedArray[Byte],
  pos : Int32,
  max_len : Int32,
  window : Int32,
  matches : FixedArray[Int32],
  count : Int32,
) -> Unit raise {
  let mut previous_len = 2
  let mut previous_offset = 0
  for i in 0..<count {
    let len = matches[2 * i]
    let offset = matches[2 * i + 1]
    assert_true(len > previous_len && len <= max_len)
    assert_true(offset >= 1 && offset < window && offset <= pos)
    assert_true(offset >= previous_offset)
    for k in 0..<len {
      assert_eq(data[pos + k], data[pos - offset + k])
    }
    previous_len = len
    previous_offset = offset
  }
}

///|
test "BtMatchfinder: full tree search gives the nearest occurrence for every length 4+" {
  // Starting with four zero bytes makes the initial zero hash exact. Without
  // that, libdeflate intentionally places position zero in bucket zero even
  // when its actual hash differs; the oracle tests pin that behavior too.
  for alphabet in [2, 3, 4, 256] {
    for window in [1, 2, 63, 128, 257] {
      let n = 1600
      let data = FixedArray::make(n, b'\x00')
      let mut state = 17U
      for i in 4..<n {
        state = (state * 1103515245U + 12345U) & 0x7fffffffU
        data[i] = ((state >> 16).reinterpret_as_int() % alphabet).to_byte()
        if i > 100 && i % 91 < 50 {
          data[i] = data[i - 71]
        }
      }
      let finder = @lz77.BtMatchfinder(
        max_distance=window,
        hash3_bits=4,
        hash4_bits=3,
      )
      let out = FixedArray::make(124, 0)
      for pos in 0..<(n - 4) {
        let max_len = (n - pos).min(64)
        let count = finder.get_matches(data, pos, max_len, max_len, 100000, out)
        bt_validate(data, pos, max_len, window, out, count)
        // The independent reference tries nearest to farthest, byte by byte,
        // and records improvements. Hash3 has only two ways, so it has no
        // completeness guarantee for length 3; every 4+ match is in the tree.
        let mut best = 3
        let mut record = if count > 0 && out[0] == 3 { 1 } else { 0 }
        for offset in 1..<window.min(pos + 1) {
          let mut len = 0
          while len < max_len && data[pos + len] == data[pos - offset + len] {
            len += 1
          }
          if len > best {
            assert_true(
              record < count,
              msg="missing at \{pos}, window \{window}",
            )
            assert_eq(out[2 * record], len, msg="length at \{pos}")
            assert_eq(out[2 * record + 1], offset, msg="nearest at \{pos}")
            record += 1
            best = len
          }
        }
        assert_eq(record, count)
      }
      assert_eq(
        finder.memory_usage(),
        @lz77.bt_memory_bound(max_distance=window, hash3_bits=4, hash4_bits=3),
      )
    }
  }
}

///|
test "BtMatchfinder: runs, finite depths, nice length, output capacity and reset" {
  for kind in ["text", "binary", "runs", "window"] {
    let data = bt_oracle_input(kind, 71000)
    for depth in [1, 2, 35] {
      let finder = @lz77.BtMatchfinder(hash3_bits=6, hash4_bits=7)
      let out = FixedArray::make(2 * (5 - 2), -99)
      for pos in 0..<(data.length() - 4) {
        let max_len = (data.length() - pos).min(258)
        if pos % 7 == 0 {
          finder.skip_byte(data, pos, 5, depth)
        } else {
          let count = finder.get_matches(data, pos, max_len, 5, depth, out)
          bt_validate(data, pos, max_len, 32768, out, count)
          assert_true(count <= 3)
        }
      }
      finder.reset()
      let fresh = @lz77.BtMatchfinder(hash3_bits=6, hash4_bits=7)
      let other = FixedArray::make(out.length(), 0)
      // Reset at a nonzero index: absolute positions and an empty history.
      for pos in 79..<1000 {
        let a = finder.get_matches(data, pos, 258, 5, depth, out)
        let b = fresh.get_matches(data, pos, 258, 5, depth, other)
        assert_eq(a, b)
        for i in 0..<(2 * a) {
          assert_eq(out[i], other[i])
        }
      }
    }
  }
  assert_eq(@lz77.BtMatchfinder().memory_usage(), 1048576L)
  assert_eq(@lz77.bt_memory_bound(), 1048576L)
  // Bounds use Int64 even for configurations larger than Int32 bytes.
  assert_eq(
    @lz77.bt_memory_bound(max_distance=1 << 29, hash3_bits=29, hash4_bits=29),
    10737418240L,
  )
}

///|
test "BtMatchfinder: the window cutoff is exclusive and buffer tails are not read" {
  for distance in [32767, 32768, 32769] {
    let n = distance + 10
    let data = FixedArray::make(n, b'\x01')
    // Position 1 is hashed normally; zero uses the initial hash zero.
    for i in 0..<5 {
      data[1 + i] = (10 + i).to_byte()
      data[1 + distance + i] = (10 + i).to_byte()
    }
    let finder = @lz77.BtMatchfinder()
    let out = FixedArray::make(6, 0)
    for pos in 0..<(1 + distance) {
      finder.skip_byte(data, pos, 5, 35)
    }
    let count = finder.get_matches(data, 1 + distance, 5, 5, 35, out)
    if distance < 32768 {
      assert_true(count > 0)
      assert_eq(out[2 * count - 1], distance)
      assert_eq(out[2 * count - 2], 5)
    } else {
      assert_eq(count, 0)
    }
  }
  // Compare an actual short buffer to the same prefix with a different tail.
  // Includes a ring wrap and all remaining lengths 5..258.
  let cut = 33000
  let short = bt_oracle_input("window", cut)
  let long = FixedArray::make(cut + 258, b'\xff')
  FixedArray::unsafe_blit(long, 0, short, 0, cut)
  let a = @lz77.BtMatchfinder()
  let b = @lz77.BtMatchfinder()
  let out_a = FixedArray::make(512, 0)
  let out_b = FixedArray::make(512, 0)
  for pos in 0..<(cut - 4) {
    let max_len = (cut - pos).min(258)
    let nice = max_len.min(75)
    let x = a.get_matches(short, pos, max_len, nice, 35, out_a)
    let y = b.get_matches(long, pos, max_len, nice, 35, out_b)
    assert_eq(x, y)
    for i in 0..<(2 * x) {
      assert_eq(out_a[i], out_b[i])
    }
  }
}

///|
test "BtMatchfinder: moving the buffer preserves matches across window edges" {
  let data = bt_oracle_input("window", 110000)
  for depth in [1, 35] {
    let whole = @lz77.BtMatchfinder()
    let slid = @lz77.BtMatchfinder()
    let moved = FixedArray::make(data.length(), b'\x00')
    FixedArray::unsafe_blit(moved, 0, data, 0, data.length())
    let expected = FixedArray::make(146, 0)
    let actual = FixedArray::make(146, 0)
    let mut base = 0
    let mut edge_matches = 0
    slid.move_down(0)
    for pos in 0..<(data.length() - 4) {
      let delta = match pos {
        // After each slide the next buffer position is 32767: traverse the
        // ring edge immediately afterwards, with the full live window kept.
        40000 => 7233
        80000 => 40000 // Greater than the tree size, and not aligned to it.
        _ => 0
      }
      if delta != 0 {
        base += delta
        FixedArray::unsafe_blit(moved, 0, data, base, data.length() - base)
        slid.move_down(delta)
        assert_eq(pos - base, 32767)
        assert_eq(slid.memory_usage(), whole.memory_usage())
      }
      let max_len = (data.length() - pos).min(258)
      let nice = max_len.min(75)
      if pos % 7 == 0 {
        whole.skip_byte(data, pos, nice, depth)
        slid.skip_byte(moved, pos - base, nice, depth)
      } else {
        let count = whole.get_matches(data, pos, max_len, nice, depth, expected)
        let found = slid.get_matches(
          moved,
          pos - base,
          max_len,
          nice,
          depth,
          actual,
        )
        assert_eq(found, count, msg="count at \{pos}, base \{base}")
        for i in 0..<(2 * count) {
          assert_eq(actual[i], expected[i], msg="match at \{pos}, base \{base}")
        }
        for i in 0..<count {
          if base > 0 && expected[2 * i + 1] == 32767 {
            edge_matches += 1
          }
        }
      }
    }
    if depth == 35 {
      assert_true(edge_matches > 0)
    }
  }
}

///|
test "BtMatchfinder: moving past all history clears positions below zero" {
  // Zero bytes also make the initial and precomputed hashes identical, so an
  // emptied finder must behave exactly like a fresh one starting at zero.
  let data = FixedArray::make(128, b'\x00')
  for delta in [0, 1, 17, 32, 65] {
    let slid = @lz77.BtMatchfinder(max_distance=17, hash3_bits=2, hash4_bits=2)
    let fresh = @lz77.BtMatchfinder(max_distance=17, hash3_bits=2, hash4_bits=2)
    let actual = FixedArray::make(6, 0)
    let expected = FixedArray::make(6, 0)
    for pos in 0..<delta {
      ignore(slid.get_matches(data, pos, 5, 5, 35, actual))
    }
    slid.move_down(delta)
    for pos in 0..<40 {
      let count = fresh.get_matches(data, pos, 5, 5, 35, expected)
      let found = slid.get_matches(data, pos, 5, 5, 35, actual)
      assert_eq(found, count)
      for i in 0..<(2 * count) {
        assert_eq(actual[i], expected[i])
      }
    }
  }
}
