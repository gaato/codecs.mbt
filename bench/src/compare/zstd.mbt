///|
/// The zstd decoders, whole input to whole output.
pub fn zstd_whole() -> Array[Whole] {
  [
    { name: "gaato/zstd", decode: input => @zstd.decompress(input), },
    {
      name: "Milky2018/zstd 0.1.4",
      decode: input => @milky_zstd.decompress(input),
    },
  ]
}

///|
/// gaato/zstd's decoder over `step_into`, as the benchmarks call it.
pub fn zstd_steps(input : BytesView, out : FixedArray[Byte]) -> Int32 {
  let decoder = @zstd.Decoder()
  let mut rest = input
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
/// The zstd decoders fed in pieces.
pub fn zstd_pieces() -> Array[Pieces] {
  [
    {
      name: "gaato/zstd",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        run_decode(@zstd.Decoder(), input, piece, out, sink)
      },
    },
    {
      name: "Milky2018/zstd 0.1.4",
      caller_buffer: false,
      run: (input, piece, _, sink) => {
        let d = @milky_zstd.new_decompressor()
        each_piece(input, piece, (chunk, last) => {
          d.push(chunk.to_owned())
          let got = if last { d.finish() } else { d.pull() }
          sink(got[:])
        })
      },
    },
  ]
}

///|
/// Runs a `gaato/codec_bytes` decoder over `input` in pieces, into an
/// output buffer of `out` bytes.
fn[D : @codec_bytes.Decode] run_decode(
  decoder : D,
  input : Bytes,
  piece : Int32,
  out : Int32,
  sink : (BytesView) -> Unit,
) -> Unit raise {
  let buf = FixedArray::make(out, b'\x00')
  each_piece(input, piece, (chunk, last) => {
    let mut rest = chunk
    for ;; {
      let status = decoder.step(rest, buf.mut_view(), end=last)
      rest = rest[decoder.last_consumed():]
      sink(Bytes::from_array(buf[:decoder.last_produced()])[:])
      match status {
        Done => return
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
  })
}
