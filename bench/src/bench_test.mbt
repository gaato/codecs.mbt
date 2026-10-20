///|
fn decode64(s : String) -> Bytes {
  @base64.decode(s, ignore_whitespace=true) catch {
    _ => abort("bad base64")
  }
}

///|
/// Decodes `input` whole into 64 KiB slices, as a consumer would, and
/// returns how many bytes came out.
fn zstd_decode(input : Bytes) -> Int32 {
  let decoder = @zstd.Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = decoder.step_into(rest, out, end=true) catch {
      _ => abort("zstd: bad stream")
    }
    rest = rest[decoder.last_consumed():]
    total += decoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
fn brotli_decode(input : Bytes) -> Int32 {
  let decoder = @brotli.Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = decoder.step_into(rest, out, end=true) catch {
      _ => abort("brotli: bad stream")
    }
    rest = rest[decoder.last_consumed():]
    total += decoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
test "decode" (b : @bench.T) {
  let zt = decode64(zstd_text)
  let zb = decode64(zstd_binary)
  let bt = decode64(brotli_text)
  let bb = decode64(brotli_binary)
  // The streams decode to their sizes before anything is timed.
  assert_eq(zstd_decode(zt), text_size)
  assert_eq(zstd_decode(zb), binary_size)
  assert_eq(brotli_decode(bt), text_size)
  assert_eq(brotli_decode(bb), binary_size)
  b.bench(name="zstd text 1 MiB", () => b.keep(zstd_decode(zt)))
  b.bench(name="zstd binary 512 KiB", () => b.keep(zstd_decode(zb)))
  b.bench(name="brotli text 1 MiB", () => b.keep(brotli_decode(bt)))
  b.bench(name="brotli binary 512 KiB", () => b.keep(brotli_decode(bb)))
}
