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
/// Encodes `input` at `level` into 64 KiB slices, its size unknown to the
/// encoder (the largest parameter class), and returns the bytes written.
fn zstd_encode(input : Bytes, level : Int32) -> Int32 {
  let encoder = @zstd.Encoder(level~)
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = encoder.step_into(rest, out, action=Finish) catch {
      _ => abort("zstd: content size")
    }
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

///|
/// Decodes a framed Snappy stream whole into 64 KiB slices, as a consumer
/// would, and returns how many bytes came out.
fn snappy_decode(input : Bytes) -> Int32 {
  let decoder = @snappy.Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = decoder.step(rest, out.mut_view(), end=true) catch {
      _ => abort("snappy: bad stream")
    }
    rest = rest[decoder.last_consumed():]
    total += decoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
/// Compresses `input` into a framed Snappy stream in 64 KiB slices with
/// `Finish`, and returns how many bytes came out.
fn snappy_encode(input : Bytes) -> Int32 {
  let encoder = @snappy.Encoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = encoder.step(rest, out.mut_view(), action=Finish)
    rest = rest[encoder.last_consumed():]
    total += encoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
test "snappy" (b : @bench.T) {
  // The inputs, as the reference decoders give them back; our streams are
  // the snap crate's, to the byte (snappy/scripts/crosscheck.mbtx).
  let text = @brotli.decompress(decode64(brotli_text)) catch {
    _ => abort("brotli: bad stream")
  }
  let binary = @brotli.decompress(decode64(brotli_binary)) catch {
    _ => abort("brotli: bad stream")
  }
  let st = @snappy.compress(text)
  let sb = @snappy.compress(binary)
  let rt = @snappy.compress_raw(text)
  assert_eq(snappy_decode(st), text_size)
  assert_eq(snappy_decode(sb), binary_size)
  b.bench(name="snappy text 512 KiB", () => b.keep(snappy_decode(st)))
  b.bench(name="snappy binary 128 KiB", () => b.keep(snappy_decode(sb)))
  b.bench(name="snappy raw text 512 KiB", () => {
    b.keep(@snappy.decompress_raw(rt) catch { _ => abort("snappy: bad") })
  })
  b.bench(name="snappy encode text 512 KiB", () => b.keep(snappy_encode(text)))
  b.bench(name="snappy encode binary 128 KiB", () => {
    b.keep(snappy_encode(binary))
  })
  b.bench(name="snappy raw encode text 512 KiB", () => {
    b.keep(@snappy.compress_raw(text))
  })
}

///|
/// Decodes an LZ4 frame whole into 64 KiB slices, as a consumer would, and
/// returns how many bytes came out.
fn lz4_decode(input : Bytes) -> Int32 {
  let decoder = @lz4.Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = decoder.step(rest, out.mut_view(), end=true) catch {
      _ => abort("lz4: bad stream")
    }
    rest = rest[decoder.last_consumed():]
    total += decoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
/// Compresses `input` into an LZ4 frame in 64 KiB slices with `Finish`,
/// and returns how many bytes came out.
fn lz4_encode(input : Bytes) -> Int32 {
  let encoder = @lz4.Encoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = encoder.step(rest, out.mut_view(), action=Finish) catch {
      _ => abort("lz4: content size")
    }
    rest = rest[encoder.last_consumed():]
    total += encoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
test "lz4" (b : @bench.T) {
  // The inputs, as the reference decoders give them back; our frames are
  // lz4's, to the byte (lz4/src/vectors_wbtest.mbt).
  let text = @brotli.decompress(decode64(brotli_text)) catch {
    _ => abort("brotli: bad stream")
  }
  let binary = @brotli.decompress(decode64(brotli_binary)) catch {
    _ => abort("brotli: bad stream")
  }
  let lt = @lz4.compress(text)
  let lb = @lz4.compress(binary)
  assert_eq(lz4_decode(lt), text_size)
  assert_eq(lz4_decode(lb), binary_size)
  b.bench(name="lz4 text 512 KiB", () => b.keep(lz4_decode(lt)))
  b.bench(name="lz4 binary 128 KiB", () => b.keep(lz4_decode(lb)))
  b.bench(name="lz4 encode text 512 KiB", () => b.keep(lz4_encode(text)))
  b.bench(name="lz4 encode binary 128 KiB", () => b.keep(lz4_encode(binary)))
}

///|
/// Decodes an LZW stream whole into 64 KiB slices, as a consumer would,
/// and returns how many bytes came out.
fn lzw_decode(input : Bytes, format : @lzw.Format) -> Int32 {
  let decoder = @lzw.Decoder(format)
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = decoder.step(rest, out.mut_view(), end=true) catch {
      _ => abort("lzw: bad stream")
    }
    rest = rest[decoder.last_consumed():]
    total += decoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
test "lzw" (b : @bench.T) {
  // The inputs, as the reference decoders give them back; our .Z is
  // compress's, to the byte (lzw/src/vectors_wbtest.mbt).
  let text = @brotli.decompress(decode64(brotli_text)) catch {
    _ => abort("brotli: bad stream")
  }
  let binary = @brotli.decompress(decode64(brotli_binary)) catch {
    _ => abort("brotli: bad stream")
  }
  let tiff = @lzw.Format::tiff()
  let z = @lzw.Format::unix_compress() catch { _ => abort("format") }
  let encode = (input : Bytes, format : @lzw.Format) => {
    @lzw.compress(input, format) catch {
      _ => abort("lzw: encode")
    }
  }
  let tt = encode(text, tiff)
  let tb = encode(binary, tiff)
  let zt = encode(text, z)
  assert_eq(lzw_decode(tt, tiff), text_size)
  assert_eq(lzw_decode(tb, tiff), binary_size)
  assert_eq(lzw_decode(zt, z), text_size)
  b.bench(name="lzw tiff text 512 KiB", () => b.keep(lzw_decode(tt, tiff)))
  b.bench(name="lzw tiff binary 128 KiB", () => b.keep(lzw_decode(tb, tiff)))
  b.bench(name="lzw .Z text 512 KiB", () => b.keep(lzw_decode(zt, z)))
  b.bench(name="lzw encode tiff text 512 KiB", () => {
    b.keep(encode(text, tiff).length())
  })
  b.bench(name="lzw encode .Z text 512 KiB", () => {
    b.keep(encode(text, z).length())
  })
}

///|
/// Decodes a PNG image whole into 64 KiB slices of rows, as a consumer
/// would, and returns how many bytes of rows came out.
fn png_decode(input : Bytes) -> Int32 {
  let decoder = @png.Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = decoder.step_into(rest, out, end=true) catch {
      _ => abort("png: bad image")
    }
    rest = rest[decoder.last_consumed():]
    total += decoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
/// Decodes a PNG image with typst's `decode_png` (the `png` crate's
/// reader, ported), and returns how many bytes of pixels came out.
fn typst_decode(input : Bytes) -> Int32 {
  let (_, pixels) = @codecs.decode_png(input) catch {
    _ => abort("typst: bad image")
  }
  pixels.length()
}

///|
test "png" (b : @bench.T) {
  let plain = decode64(@png_data.plain)
  let interlaced = decode64(@png_data.interlaced)
  let size = @png_data.width * @png_data.height * 3
  // Both decode to the image's size before anything is timed.
  assert_eq(png_decode(plain), size)
  assert_eq(png_decode(interlaced), size)
  assert_eq(typst_decode(plain), size)
  assert_eq(typst_decode(interlaced), size)
  b.bench(name="png 512x384 rgb8", () => b.keep(png_decode(plain)))
  b.bench(name="png 512x384 rgb8 adam7", () => b.keep(png_decode(interlaced)))
  b.bench(name="typst png 512x384 rgb8", () => b.keep(typst_decode(plain)))
  b.bench(name="typst png 512x384 rgb8 adam7", () => {
    b.keep(typst_decode(interlaced))
  })
}

///|
test "zstd encode" (b : @bench.T) {
  let text = @zstd.decompress(decode64(zstd_text)) catch {
    _ => abort("zstd: bad stream")
  }
  let binary = @zstd.decompress(decode64(zstd_binary)) catch {
    _ => abort("zstd: bad stream")
  }
  assert_eq(text.length(), text_size)
  assert_eq(binary.length(), binary_size)
  for level in [1, 3, 5, 8, 12] {
    b.bench(name="zstd encode text 512 KiB level \{level}", () => {
      b.keep(zstd_encode(text, level))
    })
  }
  for level in [1, 3, 12] {
    b.bench(name="zstd encode binary 128 KiB level \{level}", () => {
      b.keep(zstd_encode(binary, level))
    })
  }
}
