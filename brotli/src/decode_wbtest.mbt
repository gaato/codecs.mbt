///|
test "every vector decodes to its original" {
  for v in vectors {
    let got = decompress(v.input())
    assert_eq(got.length(), v.size, msg=v.name)
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "any fixed input split and output size give the same output" {
  let splits : Array[(Int32, Int32)] = [
    (1, 1 << 16),
    (1 << 20, 1),
    (1, 1),
    (3, 7),
    (7, 3),
    (64, 4096),
    (4096, 64),
  ]
  for v in vectors {
    // Byte-sized steps over the 5 MiB vector would only add run time.
    guard v.size <= 300000 else { continue }
    let input = v.input()
    for split in splits {
      let (in_chunk, out_chunk) = split
      if in_chunk * out_chunk < 64 && v.size > 20000 {
        continue
      }
      let got = stream(input, in_chunk~, out_chunk~)
      assert_eq(
        @checksum.sha256(got),
        v.sha256,
        msg="\{v.name} in \{in_chunk} out \{out_chunk}",
      )
    }
  }
}

///|
test "random input splits and output sizes give the same output" {
  let rng = Rng::new(7932)
  for v in vectors {
    let input = v.input()
    for round in 0..<3 {
      let max_in = [1, 17, 1500][round]
      let max_out = [5000, 3, 70000][round]
      let got = drive(
        Decoder(),
        input,
        next_in=() => 1 + rng.below(max_in),
        next_out=() => 1 + rng.below(max_out),
        fixed=round != 1,
      )
      assert_eq(@checksum.sha256(got), v.sha256, msg="\{v.name} round \{round}")
    }
  }
}

///|
test "every proper prefix of a stream is truncated" {
  for v in vectors {
    let input = v.input()
    guard input.length() <= 2000 else { continue }
    for cut in 0..<input.length() {
      let outcome = try decompress(input[:cut]) catch {
        BrotliError(kind, _) => kind
      } noraise {
        _ => fail("\{v.name} cut at \{cut} decoded")
      }
      assert_eq(outcome, Truncated, msg="\{v.name} cut at \{cut}")
    }
  }
}

///|
test "bytes after the end are refused in the same step or a later one" {
  let input = b"\x06"
  let decoder = Decoder()
  let out = FixedArray::make(8, b'\x00')
  debug_inspect(decoder.step_into(input, out), content="Done")
  assert_true(decoder.is_finished())
  // An empty step after the end is fine; a byte is not.
  debug_inspect(decoder.step_into(b"", out, end=true), content="Done")
  let late = try decoder.step_into(b"\x00", out) catch {
    BrotliError(kind, _) => kind
  } noraise {
    _ => fail("trailing byte accepted")
  }
  debug_inspect(late, content="TrailingData")
  // The error sticks until `reset`.
  let again = try decoder.step_into(b"", out) catch {
    BrotliError(kind, _) => kind
  } noraise {
    _ => fail("error forgotten")
  }
  debug_inspect(again, content="TrailingData")
  inspect(decoder.last_consumed(), content="0")
  inspect(decoder.last_produced(), content="0")
  decoder.reset()
  debug_inspect(decoder.step_into(input, out, end=true), content="Done")
}

///|
test "a decoder is reused across streams after reset" {
  let decoder = Decoder()
  for v in vectors {
    guard v.size <= 300000 else { continue }
    decoder.reset()
    let got = drive(decoder, v.input(), next_in=() => 999, next_out=() => 4096)
    assert_eq(@checksum.sha256(got), v.sha256, msg=v.name)
  }
}

///|
test "decompress honours max_output" {
  let alice = vectors
    .search_by(v => v.name == "alice29.txt.compressed")
    .unwrap()
  let input = vectors[alice].input()
  inspect(decompress(input, max_output=152089).length(), content="152089")
  let refused = try decompress(input, max_output=152088) catch {
    BrotliError(kind, message) => "\{Repr(kind)}: \{message}"
  } noraise {
    _ => fail("limit ignored")
  }
  inspect(
    refused,
    content="OutputLimitExceeded: the output exceeds 152088 bytes",
  )
}

///|
test "max_window_bits refuses larger windows and is clamped" {
  let far = vectors.search_by(v => v.name == "gen/window24_far").unwrap()
  let input = vectors[far].input()
  for bits in [10, 23] {
    let refused = try decompress(input, max_window_bits=bits) catch {
      BrotliError(kind, _) => kind
    } noraise {
      _ => fail("window over \{bits} bits accepted")
    }
    assert_eq(refused, WindowTooLarge)
  }
  assert_eq(decompress(input, max_window_bits=99).length(), vectors[far].size)
  // A 16-bit window passes a limit of 16 (and of 3, clamped up to 10, fails).
  let small = BitWriter::new().bits(1, 0).bits(2, 3).finish()
  inspect(decompress(small, max_window_bits=16).length(), content="0")
  let clamped = try decompress(small, max_window_bits=3) catch {
    BrotliError(kind, _) => kind
  } noraise {
    _ => fail("16-bit window under a 10-bit limit accepted")
  }
  assert_eq(clamped, WindowTooLarge)
}
