///|
test "repeat offsets: independent RFC transitions and inverse, including zero literals" {
  let history = @seqenc.Repeats()
  let model : FixedArray[UInt32] = [1, 4, 8]
  let mut seed = 8878U
  for i in 0..<5000 {
    seed = seed * 1664525 + 1013904223
    let ll = if i % 2 == 0 { 0 } else { 1 }
    let value = if i < 100 {
      (i % 3 + 1).reinterpret_as_uint()
    } else {
      (seed >> 24) + 1
    }
    let v = if value == 3 && ll == 0 && model[0] == 1 { 4U } else { value }
    let saved = @seqenc.Repeats()
    saved.copy_from(history)
    let expected = if v > 3 {
      let d = v - 3
      model[2] = model[1]
      model[1] = model[0]
      model[0] = d
      d
    } else if ll != 0 && v == 1 {
      model[0]
    } else {
      let k = v.reinterpret_as_int() - (if ll == 0 { 0 } else { 1 })
      let d = if k == 3 { model[0] - 1 } else { model[k] }
      if k >= 2 {
        model[2] = model[1]
      }
      model[1] = model[0]
      model[0] = d
      d
    }
    assert_true(
      history.resolve(@seqenc.OffsetValue(v), ll) == @seqenc.Distance(expected),
    )
    for k in 0..<3 {
      assert_true(history.get(k) == @seqenc.Distance(model[k]))
    }
    let old = @seqenc.Repeats()
    old.copy_from(saved)
    let inverse = saved.encode(@seqenc.Distance(expected), ll)
    // The same distance may have several legal codes, with different
    // history updates. Replay the selected value from the original state.
    assert_true(old.resolve(inverse, ll) == @seqenc.Distance(expected))
    for k in 0..<3 {
      assert_true(old.get(k) == saved.get(k))
    }
    let @seqenc.OffsetValue(code) = inverse
    assert_true(code >= 1)
  }
  history.reset()
  for i, n in [1U, 4U, 8U] {
    assert_true(history.get(i) == @seqenc.Distance(n))
  }
  // repeat 3 minus 1 gives zero here; the decoder must reject it.
  assert_true(history.resolve(@seqenc.OffsetValue(3), 0) == @seqenc.Distance(0))
}

///|
test "offset extra bits include width 31 and sequence counts have all three formats" {
  for v in [1U, 2U, 3U, 4U, 0x7fffffffU, 0x80000000U, 0xffffffffU] {
    let (code, extra) = @seqenc.offset_code(@seqenc.OffsetValue(v))
    assert_eq((1U << code) + extra, v)
    let out = @bits.BitPacker()
    // All partial byte alignments exercise the JS 32-bit accumulator.
    for prefix in 0..<8 {
      out.write(prefix, 0)
      out.write(code, extra.reinterpret_as_int())
      out.write_end_mark()
    }
    assert_true(out.pending() > 0)
  }
  for n in [0, 1, 127, 128, 255, 256, 0x7eff, 0x7f00, 43690] {
    let out = @bits.BitPacker()
    @seqenc.write_count(out, n)
    let bytes = FixedArray::make(out.pending(), b'\x00')
    out.drain_into(bytes, 0) |> ignore
    let got = if bytes[0] < b'\x80' {
      bytes[0].to_int()
    } else if bytes[0] < b'\xff' {
      ((bytes[0].to_int() - 128) << 8) + bytes[1].to_int()
    } else {
      0x7f00 + bytes[1].to_int() + (bytes[2].to_int() << 8)
    }
    assert_eq(got, n)
    assert_eq(
      bytes.length(),
      if n < 128 {
        1
      } else if n < 0x7f00 {
        2
      } else {
        3
      },
    )
  }
}
