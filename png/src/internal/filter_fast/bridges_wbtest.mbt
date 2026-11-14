///|
#cfg(any(target="native", target="wasm"))
/// A row of `n` bytes, byte `i` holding `i * 7 + seed`, wrapped.
fn row_of(n : Int32, seed : Int32) -> FixedArray[Byte] {
  FixedArray::makei(n, i => (i * 7 + seed).to_byte())
}

///|
#cfg(any(target="native", target="wasm"))
test "load16 and store16 read and write exactly the sixteen bytes from off" {
  for n in [16, 17, 31, 40] {
    for off in 0..<=(n - 16) {
      let a = row_of(n, 3)
      let v = load16(a, off)
      let b = FixedArray::make(n, b'\xAA')
      store16(b, off, v)
      for i in 0..<n {
        let want = if i >= off && i < off + 16 { a[i] } else { b'\xAA' }
        assert_eq(b[i], want, msg="n=\{n} off=\{off} i=\{i}")
      }
    }
  }
}

///|
#cfg(any(target="native", target="wasm"))
test "add16 adds each byte, wrapped modulo 256, for every pair of bytes" {
  // Every pair (x, y) of bytes, sixteen pairs to a vector, in every lane.
  let xs = FixedArray::make(16, b'\x00')
  let ys = FixedArray::make(16, b'\x00')
  let out = FixedArray::make(16, b'\x00')
  for x in 0..<256 {
    for y0 in 0..<16 {
      for lane in 0..<16 {
        xs[lane] = x.to_byte()
        ys[lane] = (y0 * 16 + lane).to_byte()
      }
      store16(out, 0, add16(load16(xs, 0), load16(ys, 0)))
      for lane in 0..<16 {
        assert_eq(out[lane].to_int(), (x + y0 * 16 + lane) % 256)
      }
    }
  }
}

///|
#cfg(any(target="native", target="wasm"))
test "store4 writes exactly the four bytes from off" {
  for n in [4, 5, 16, 20] {
    for off in 0..<=(n - 4) {
      let src = row_of(16, 5)
      let b = FixedArray::make(n, b'\xAA')
      store4(b, off, load16(src, 0))
      for i in 0..<n {
        let want = if i >= off && i < off + 4 { src[i - off] } else { b'\xAA' }
        assert_eq(b[i], want, msg="n=\{n} off=\{off} i=\{i}")
      }
    }
  }
}

///|
#cfg(any(target="native", target="wasm"))
test "avg16 is the mean rounded down, for every pair of bytes" {
  let xs = FixedArray::make(16, b'\x00')
  let ys = FixedArray::make(16, b'\x00')
  let out = FixedArray::make(16, b'\x00')
  for x in 0..<256 {
    for y0 in 0..<16 {
      for lane in 0..<16 {
        xs[lane] = x.to_byte()
        ys[lane] = (y0 * 16 + lane).to_byte()
      }
      store16(out, 0, avg16(load16(xs, 0), load16(ys, 0)))
      for lane in 0..<16 {
        assert_eq(out[lane].to_int(), (x + y0 * 16 + lane) / 2)
      }
    }
  }
}

///|
#cfg(any(target="native", target="wasm"))
test "paeth16 is @filter.paeth in its first eight bytes, for every three bytes" {
  // Every (a, b, c), eight values of c to a vector; the upper eight bytes
  // of the result repeat the lower eight.
  let as_ = FixedArray::make(16, b'\x00')
  let bs = FixedArray::make(16, b'\x00')
  let cs = FixedArray::make(16, b'\x00')
  let out = FixedArray::make(16, b'\x00')
  for a in 0..<256 {
    for b in 0..<256 {
      for c0 in 0..<32 {
        for lane in 0..<16 {
          as_[lane] = a.to_byte()
          bs[lane] = b.to_byte()
          cs[lane] = (c0 * 8 + lane % 8).to_byte()
        }
        store16(out, 0, paeth16(load16(as_, 0), load16(bs, 0), load16(cs, 0)))
        for lane in 0..<16 {
          let want = @filter.paeth(a, b, c0 * 8 + lane % 8)
          if out[lane].to_int() != want {
            fail("a=\{a} b=\{b} c=\{c0 * 8 + lane % 8} lane=\{lane}")
          }
        }
      }
    }
  }
}
