///|
fn decode64(s : String) -> Bytes {
  @base64.decode(s, ignore_whitespace=true) catch {
    _ => abort("bad base64")
  }
}

///|
/// gaato/png's streaming decoder into 64 KiB slices of rows, as
/// `bench_test.mbt` of the parent package times it: the bytes of rows that
/// came out.
fn gaato_rows(input : Bytes) -> Int32 {
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
/// The same, with each row converted to RGBA, 8 bits a sample, as the
/// decoders that give only RGBA hand it out: the bytes of RGBA.
fn gaato_rgba8(input : Bytes) -> Int32 {
  let decoder = @png.Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rgba = FixedArray::make(0, b'\x00')
  let mut converter = None
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = decoder.step_into(rest, out, end=true) catch {
      _ => abort("png: bad image")
    }
    rest = rest[decoder.last_consumed():]
    match status {
      Frame => {
        converter = Some(decoder.converter())
        rgba = FixedArray::make(decoder.width() * 4, b'\x00')
      }
      Rows => {
        guard converter is Some(c) else { abort("rows before Frame") }
        let row = decoder.row_bytes()
        let pixels = (
            decoder.width() - decoder.pass_x() + decoder.pass_dx() - 1
          ) /
          decoder.pass_dx()
        for i in 0..<decoder.rows_count() {
          c.rgba8(out[i * row:(i + 1) * row], pixels, rgba.mut_view())
          total += pixels * 4
        }
      }
      Done => return total
      _ => ()
    }
  }
}

///|
/// The bytes of pixels the package named `name` gives, in its own format.
fn native(name : String, input : Bytes) -> Int32 {
  let (_, _, n) = @compare_png.decode_native(name, input) catch {
    _ => abort("\{name}: bad image")
  }
  n
}

///|
/// The benchmarks' images, and what gaato/png makes of them, which every
/// decoder must give before it is timed.
fn images() -> (Bytes, Bytes, @compare_png.Rgba16) {
  let plain = decode64(@png_data.plain)
  let interlaced = decode64(@png_data.interlaced)
  let want = @compare_png.gaato(plain) catch { _ => abort("gaato: bad image") }
  (plain, interlaced, want)
}

///|
/// Whether `decoder` gives `want` for `input`.
fn gives(decoder : String, input : Bytes, want : @compare_png.Rgba16) -> Bool {
  (@compare_png.decode_with(decoder, input) catch { _ => return false }).same(
    want,
  )
}

///|
test "gaato" (b : @bench.T) {
  let (plain, interlaced, want) = images()
  let pixels = @png_data.width * @png_data.height
  assert_true(gives("gaato", interlaced, want))
  assert_eq(gaato_rows(plain), pixels * 3)
  assert_eq(gaato_rows(interlaced), pixels * 3)
  assert_eq(gaato_rgba8(plain), pixels * 4)
  assert_eq(gaato_rgba8(interlaced), pixels * 4)
  b.bench(name="gaato png 512x384 rgb8", () => b.keep(gaato_rows(plain)))
  b.bench(name="gaato png 512x384 rgb8 adam7", () => {
    b.keep(gaato_rows(interlaced))
  })
  b.bench(name="gaato+rgba8 png 512x384 rgb8", () => b.keep(gaato_rgba8(plain)))
  b.bench(name="gaato+rgba8 png 512x384 rgb8 adam7", () => {
    b.keep(gaato_rgba8(interlaced))
  })
}

///|
test "typst" (b : @bench.T) {
  let (plain, interlaced, want) = images()
  assert_true(gives("typst", plain, want))
  assert_true(gives("typst", interlaced, want))
  b.bench(name="typst png 512x384 rgb8", () => b.keep(native("typst", plain)))
  b.bench(name="typst png 512x384 rgb8 adam7", () => {
    b.keep(native("typst", interlaced))
  })
}

///|
test "mizchi" (b : @bench.T) {
  let (plain, interlaced, want) = images()
  assert_true(gives("mizchi", plain, want))
  // mizchi/image does not read interlaced images.
  assert_true(!gives("mizchi", interlaced, want))
  b.bench(name="mizchi png 512x384 rgb8", () => b.keep(native("mizchi", plain)))
}
