///|
/// The Brotli decoders, whole input to whole output.
pub fn brotli_whole() -> Array[Whole] {
  [
    { name: "gaato/brotli", decode: input => @brotli.decompress(input), },
    {
      name: "hustcer/fbr 0.8.2",
      decode: input => of_fixed(@fbr.unbrotli_sync(input.to_fixedarray())),
    },
    {
      name: "mizchi/brotli 0.2.2",
      decode: input => @mizchi_brotli.brotli_decompress(input),
    },
  ]
}

///|
/// gaato/brotli's decoder over `step_into`, as the benchmarks call it.
pub fn brotli_steps(input : BytesView, out : FixedArray[Byte]) -> Int32 {
  let decoder = @brotli.Decoder()
  let mut rest = input
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
/// The Brotli decoders fed in pieces.
pub fn brotli_pieces() -> Array[Pieces] {
  [
    {
      name: "gaato/brotli",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        run_decode(@brotli.Decoder(), input, piece, out, sink)
      },
    },
    {
      name: "hustcer/fbr 0.8.2",
      caller_buffer: false,
      run: (input, piece, _, sink) => {
        let s = @fbr_decode.UnbrotliStream::new()
        s.set_ondata((data, _) => sink(of_fixed(data)[:]))
        each_piece(input, piece, (chunk, last) => {
          s.push(chunk.to_owned().to_fixedarray(), final_=last)
        })
      },
    },
  ]
}

///|
/// The Brotli encoders. gaato/brotli has no quality levels: it is called
/// with its defaults at every level.
pub fn brotli_compress() -> Array[Compress] {
  [
    {
      name: "gaato/brotli",
      default_level: 0,
      max_level: 0,
      encode: (input, _) => @brotli.compress(input),
    },
    {
      name: "hustcer/fbr 0.8.2",
      default_level: 11,
      max_level: 11,
      encode: (input, level) => {
        let opts = { ..@fbr_encode.BrotliOptions::default(), quality: level, }
        of_fixed(@fbr.brotli_sync(input.to_fixedarray(), opts~))
      },
    },
    {
      name: "mizchi/brotli 0.2.2",
      default_level: 1,
      max_level: 1,
      encode: (input, level) => {
        @mizchi_brotli.brotli_compress_with_quality(input, level)
      },
    },
  ]
}
