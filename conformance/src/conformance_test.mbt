///|
/// The checks of the contract, over every vector of a format: every split
/// agrees and stays within `memory_limit`, prefixes are `Truncated`, each of
/// `garbage` after a stream is `TrailingData`, a decoder that stops after
/// the first member leaves the next vector unread (for vectors that
/// `one_member` says hold a single member), and `reset` forgets. `make`
/// builds a decoder for a window of the given bits.
fn[D : @codec_bytes.Decode] conform(
  label : String,
  vectors : Array[Vector],
  make : (Int32, @codec_bytes.Until) -> D,
  memory_limit~ : (Int32) -> Int32,
  garbage~ : Array[Bytes],
  one_member~ : (Vector) -> Bool,
) -> Unit raise {
  for i, v in vectors {
    let input = v.input()
    let codec = () => {
      @codec_harness.ByteDecoder::new(make(v.window_bits, EndOfInput))
    }
    let whole = @codec_harness.check_splits(
      codec,
      input,
      memory_limit=Some(memory_limit(v.window_bits)),
    ) catch {
      e => fail("\{label} \{v.name}: \{e}")
    }
    if whole.error is Some(_) ||
      whole.output.length() != v.size ||
      @codec_harness.sha256(whole.output) != v.sha256 {
      fail("\{label} \{v.name}: does not decode to its original")
    }
    @codec_harness.check_truncation(codec, input, whole, max_prefixes=64) catch {
      e => fail("\{label} \{v.name}: \{e}")
    }
    @codec_harness.check_trailing(codec, input, garbage~) catch {
      e => fail("\{label} \{v.name}: \{e}")
    }
    guard one_member(v) else { continue }
    let next = vectors[(i + 1) % vectors.length()].input()
    let first_member = () => {
      @codec_harness.ByteDecoder::new(make(v.window_bits, EndOfMember))
    }
    @codec_harness.check_member(first_member, input, next, whole) catch {
      e => fail("\{label} \{v.name} until=EndOfMember: \{e}")
    }
  }
  let first = vectors[0].input()
  let last = vectors[vectors.length() - 1].input()
  let wide = () => @codec_harness.ByteDecoder::new(make(24, EndOfInput))
  @codec_harness.check_reset(wide, last, first) catch {
    e => fail("\{label} reset: \{e}")
  }
}
