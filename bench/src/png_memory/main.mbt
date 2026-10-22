///|
/// The bytes of rows of the PNG image in `b64`, decoded into 64 KiB slices.
fn rows_of(b64 : String) -> Int32 {
  let input = @base64.decode(b64, ignore_whitespace=true) catch {
    _ => abort("bad base64")
  }
  let decoder = @png.Decoder()
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  let mut total = 0
  for ;; {
    let status = decoder.step(rest, out.mut_view(), end=true) catch {
      _ => abort("bad image")
    }
    rest = rest[decoder.last_consumed():]
    total += decoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
fn main {
  let mut total = 0
  for _ in 0..<10 {
    total += rows_of(@png_data.plain) + rows_of(@png_data.interlaced)
  }
  println(total)
}
