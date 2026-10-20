///|
/// The checks of the contract, over every vector of a format.
fn[D : @codec_bytes.Decode] conform(
  label : String,
  vectors : Array[Vector],
  make : (Int32) -> D,
  garbage~ : Array[Bytes]?,
) -> Unit raise {
  for v in vectors {
    let input = v.input()
    let codec = () => @codec_harness.ByteDecoder::new(make(v.window_bits))
    let whole = @codec_harness.check_splits(codec, input) catch {
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
    if garbage is Some(garbage) {
      @codec_harness.check_trailing(codec, input, garbage~) catch {
        e => fail("\{label} \{v.name}: \{e}")
      }
    }
  }
  let first = vectors[0].input()
  let last = vectors[vectors.length() - 1].input()
  let wide = () => @codec_harness.ByteDecoder::new(make(24))
  @codec_harness.check_reset(wide, last, first) catch {
    e => fail("\{label} reset: \{e}")
  }
}
