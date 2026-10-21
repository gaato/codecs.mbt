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
fn deflate_decode(input : BytesView) -> Int32 {
  let decoder = @deflate.Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input
  let mut total = 0
  for ;; {
    let status = decoder.step_into(rest, out, end=true) catch {
      _ => abort("deflate: bad stream")
    }
    rest = rest[decoder.last_consumed():]
    total += decoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
/// The raw DEFLATE data of a member `gzip -n` wrote: after its 10-byte
/// header (no name, no extra fields) and before its 8-byte trailer.
fn gzip_body(gz : Bytes) -> BytesView {
  guard gz[3] == b'\x00' else { abort("gzip: header with fields") }
  gz[10:gz.length() - 8]
}

///|
/// Compresses `input` whole into 64 KiB slices with `Finish`, as a consumer
/// would, and returns how many bytes came out.
fn brotli_encode(input : Bytes) -> Int32 {
  let encoder = @brotli.Encoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = encoder.step_into(rest, out, action=Finish)
    rest = rest[encoder.last_consumed():]
    total += encoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
fn deflate_encode(input : Bytes) -> Int32 {
  let encoder = @deflate.Encoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = encoder.step_into(rest, out, action=Finish)
    rest = rest[encoder.last_consumed():]
    total += encoder.last_produced()
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
  let dt = gzip_body(decode64(gzip_text))
  let db = gzip_body(decode64(gzip_binary))
  // The streams decode to their sizes before anything is timed.
  assert_eq(zstd_decode(zt), text_size)
  assert_eq(zstd_decode(zb), binary_size)
  assert_eq(brotli_decode(bt), text_size)
  assert_eq(brotli_decode(bb), binary_size)
  assert_eq(deflate_decode(dt), text_size)
  assert_eq(deflate_decode(db), binary_size)
  b.bench(name="zstd text 512 KiB", () => b.keep(zstd_decode(zt)))
  b.bench(name="zstd binary 128 KiB", () => b.keep(zstd_decode(zb)))
  b.bench(name="brotli text 512 KiB", () => b.keep(brotli_decode(bt)))
  b.bench(name="brotli binary 128 KiB", () => b.keep(brotli_decode(bb)))
  b.bench(name="deflate text 512 KiB", () => b.keep(deflate_decode(dt)))
  b.bench(name="deflate binary 128 KiB", () => b.keep(deflate_decode(db)))
}

///|
test "encode" (b : @bench.T) {
  // The inputs, as the reference decoders give them back.
  let text = @brotli.decompress(decode64(brotli_text)) catch {
    _ => abort("brotli: bad stream")
  }
  let binary = @brotli.decompress(decode64(brotli_binary)) catch {
    _ => abort("brotli: bad stream")
  }
  assert_eq(text.length(), text_size)
  assert_eq(binary.length(), binary_size)
  b.bench(name="brotli encode text 512 KiB", () => b.keep(brotli_encode(text)))
  b.bench(name="brotli encode binary 128 KiB", () => {
    b.keep(brotli_encode(binary))
  })
  b.bench(name="deflate encode text 512 KiB", () => b.keep(deflate_encode(text)))
  b.bench(name="deflate encode binary 128 KiB", () => {
    b.keep(deflate_encode(binary))
  })
}
