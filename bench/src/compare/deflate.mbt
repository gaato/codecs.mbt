///|
/// Converts `Bytes` to the `FixedArray[Byte]` hustcer/fzip takes.
fn fixed(input : Bytes) -> FixedArray[Byte] {
  input.to_fixedarray()
}

///|
/// The raw DEFLATE decoders, whole input to whole output.
pub fn deflate_whole() -> Array[Whole] {
  [
    { name: "gaato/deflate", decode: input => @deflate.decompress(input), },
    {
      name: "moonbit-community/flate 0.10.0",
      decode: input => @flate.inflate_all(input),
    },
    {
      name: "gmlewis/flate 0.36.17",
      decode: input => {
        collect(sink => gm_inflate(Trickle::new(input, 1 << 30), 1 << 16, sink))
      },
    },
    {
      name: "mizchi/zlib 0.4.10",
      decode: input => @mizchi_zlib.deflate_decompress(input),
    },
    {
      name: "hustcer/fzip 0.8.8",
      decode: input => of_fixed(@fzip.inflate_sync(fixed(input))),
    },
  ]
}

///|
/// The zlib decoders, whole input to whole output.
pub fn zlib_whole() -> Array[Whole] {
  [
    { name: "gaato/deflate", decode: input => @zlib.decompress(input), },
    {
      name: "moonbit-community/flate 0.10.0",
      decode: input => @flate_zlib.decompress(input),
    },
    {
      name: "gmlewis/zlib 0.21.17",
      decode: input => {
        collect(sink => gm_unzlib(Trickle::new(input, 1 << 30), 1 << 16, sink))
      },
    },
    {
      name: "mizchi/zlib 0.4.10",
      decode: input => @mizchi_zlib.zlib_decompress(input),
    },
    {
      name: "hustcer/fzip 0.8.8",
      decode: input => of_fixed(@fzip.unzlib_sync(fixed(input))),
    },
  ]
}

///|
/// The zlib decoders that take a preset dictionary, whole input to whole
/// output: `decode(dictionary ++ input)` is not how they are called, so the
/// dictionary comes first, then the stream.
pub fn zlib_dictionary() -> Array[(String, (Bytes, Bytes) -> Bytes raise)] {
  [
    ("gaato/deflate", (input, dict) => @zlib.decompress(input, dictionary=dict)),
    (
      "moonbit-community/flate 0.10.0",
      (input, dict) => {
        let d = @flate_zlib.Decoder(dictionary=dict)
        let out = Buffer()
        let buf = FixedArray::make(1 << 16, b'\x00')
        let mut rest = input[:]
        for ;; {
          let status = d.step_into(rest, buf, end=true)
          rest = rest[d.last_consumed():]
          out.write_bytesview(Bytes::from_array(buf[:d.last_produced()])[:])
          if status is Done {
            break
          }
        }
        out.to_bytes()
      },
    ),
    (
      "gmlewis/zlib 0.21.17",
      (input, dict) => {
        let (r, err) = @gm_zlib.Reader::new_dict(
          Trickle::new(input, 1 << 30),
          @gm_io.Slice::new(dict.to_array()),
        )
        check_io(err)
        collect(sink => gm_drain(b => @gm_io.Reader::read(r, b), 1 << 16, sink))
      },
    ),
    (
      "hustcer/fzip 0.8.8",
      (input, dict) => {
        let opts = {
          ..@fzip.UnzlibOptions::default(),
          dictionary: Some(fixed(dict)),
        }
        of_fixed(@fzip.unzlib_sync(fixed(input), opts~))
      },
    ),
  ]
}

///|
/// The gzip decoders, whole input to whole output.
pub fn gzip_whole() -> Array[Whole] {
  [
    { name: "gaato/deflate", decode: input => @gzip.decompress(input), },
    {
      name: "moonbit-community/flate 0.10.0",
      decode: input => @flate_gzip.decompress(input),
    },
    {
      name: "gmlewis/gzip 0.34.17",
      decode: input => {
        collect(sink => gm_gunzip(Trickle::new(input, 1 << 30), 1 << 16, sink))
      },
    },
    {
      name: "mizchi/zlib 0.4.10",
      decode: input => @mizchi_zlib.gzip_decompress(input),
    },
    {
      name: "hustcer/fzip 0.8.8",
      decode: input => of_fixed(@fzip.gunzip_sync(fixed(input))),
    },
  ]
}

///|
/// gaato/deflate's raw decoder over `step_into`, as the benchmarks call it.
pub fn deflate_steps(input : BytesView, out : FixedArray[Byte]) -> Int32 {
  let decoder = @deflate.Decoder()
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
/// moonbit-community/flate's raw decoder over `step_into`, the same way.
pub fn flate_steps(input : BytesView, out : FixedArray[Byte]) -> Int32 {
  let decoder = @flate.Inflater()
  let mut rest = input
  let mut total = 0
  for ;; {
    let status = decoder.step_into(rest, out, end=true) catch {
      _ => abort("flate: bad stream")
    }
    rest = rest[decoder.last_consumed():]
    total += decoder.last_produced()
    if status is Done {
      return total
    }
  }
}

///|
/// Runs moonbit-community/flate's `step` over `input` in pieces.
fn flate_run(
  step : (BytesView, MutArrayView[Byte], Bool) -> @flate.Status raise,
  consumed : () -> Int32,
  produced : () -> Int32,
  input : Bytes,
  piece : Int32,
  out : Int32,
  sink : (BytesView) -> Unit,
) -> Unit raise {
  let buf = FixedArray::make(out, b'\x00')
  each_piece(input, piece, (chunk, last) => {
    let mut rest = chunk
    for ;; {
      let status = step(rest, buf.mut_view(), last)
      rest = rest[consumed():]
      sink(Bytes::from_array(buf[:produced()])[:])
      match status {
        Done => return
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
  })
}

///|
/// Runs one of hustcer/fzip's streams over `input` in pieces.
fn fzip_run(
  push : (FixedArray[Byte], Bool) -> Unit raise,
  input : Bytes,
  piece : Int32,
) -> Unit raise {
  each_piece(input, piece, (chunk, last) => push(fixed(chunk.to_owned()), last))
}

///|
/// The raw DEFLATE decoders fed in pieces.
pub fn deflate_pieces() -> Array[Pieces] {
  [
    {
      name: "gaato/deflate",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        run_decode(@deflate.Decoder(), input, piece, out, sink)
      },
    },
    {
      name: "moonbit-community/flate 0.10.0",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        let d = @flate.Inflater()
        flate_run(
          (i, o, end) => d.step(i, o, end~),
          () => d.last_consumed(),
          () => d.last_produced(),
          input,
          piece,
          out,
          sink,
        )
      },
    },
    {
      name: "gmlewis/flate 0.36.17",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        gm_inflate(Trickle::new(input, piece), out, sink)
      },
    },
    {
      name: "hustcer/fzip 0.8.8",
      caller_buffer: false,
      run: (input, piece, _, sink) => {
        let s = @fzip.InflateStream::new()
        s.ondata = Some(
          @fzip.FlateStreamHandler((d, _) => sink(of_fixed(d)[:])),
        )
        fzip_run((c, last) => s.push(c, final_=last), input, piece)
      },
    },
  ]
}

///|
/// The zlib decoders fed in pieces.
pub fn zlib_pieces() -> Array[Pieces] {
  [
    {
      name: "gaato/deflate",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        run_decode(@zlib.Decoder(), input, piece, out, sink)
      },
    },
    {
      name: "moonbit-community/flate 0.10.0",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        let d = @flate_zlib.Decoder()
        flate_run(
          (i, o, end) => d.step(i, o, end~),
          () => d.last_consumed(),
          () => d.last_produced(),
          input,
          piece,
          out,
          sink,
        )
      },
    },
    {
      name: "gmlewis/zlib 0.21.17",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        gm_unzlib(Trickle::new(input, piece), out, sink)
      },
    },
    {
      name: "hustcer/fzip 0.8.8",
      caller_buffer: false,
      run: (input, piece, _, sink) => {
        let s = @fzip.UnzlibStream::new()
        s.ondata = Some(
          @fzip.FlateStreamHandler((d, _) => sink(of_fixed(d)[:])),
        )
        fzip_run((c, last) => s.push(c, final_=last), input, piece)
      },
    },
  ]
}

///|
/// The gzip decoders fed in pieces.
pub fn gzip_pieces() -> Array[Pieces] {
  [
    {
      name: "gaato/deflate",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        run_decode(@gzip.Decoder(), input, piece, out, sink)
      },
    },
    {
      name: "moonbit-community/flate 0.10.0",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        let d = @flate_gzip.Decoder()
        flate_run(
          (i, o, end) => d.step(i, o, end~),
          () => d.last_consumed(),
          () => d.last_produced(),
          input,
          piece,
          out,
          sink,
        )
      },
    },
    {
      name: "gmlewis/gzip 0.34.17",
      caller_buffer: true,
      run: (input, piece, out, sink) => {
        gm_gunzip(Trickle::new(input, piece), out, sink)
      },
    },
    {
      name: "hustcer/fzip 0.8.8",
      caller_buffer: false,
      run: (input, piece, _, sink) => {
        let s = @fzip.GunzipStream::new()
        s.ondata = Some(
          @fzip.FlateStreamHandler((d, _) => sink(of_fixed(d)[:])),
        )
        fzip_run((c, last) => s.push(c, final_=last), input, piece)
      },
    },
  ]
}

///|
/// The raw DEFLATE encoders. gmlewis/flate's writer and mizchi/zlib have no
/// level to set: they are called at 0, as gaato/brotli is.
pub fn deflate_compress() -> Array[Compress] {
  [
    {
      name: "gaato/deflate",
      default_level: 6,
      max_level: 9,
      encode: (input, level) => @deflate.compress(input, level~),
    },
    {
      name: "moonbit-community/flate 0.10.0",
      default_level: 6,
      max_level: 9,
      encode: (input, level) => @flate.deflate_all(input, level~),
    },
    {
      name: "gmlewis/flate 0.36.17",
      default_level: 0,
      max_level: 0,
      encode: (input, _) => {
        gm_compress(input, dst => {
          let w = @gm_flate.Writer::new(dst)
          (b => w.write(b), () => w.close())
        })
      },
    },
    {
      name: "mizchi/zlib 0.4.10",
      default_level: 0,
      max_level: 0,
      // deflate_compress is deflate_compress_best on every target.
      encode: (input, _) => @mizchi_zlib.deflate_compress(input),
    },
    {
      name: "hustcer/fzip 0.8.8",
      default_level: 6,
      max_level: 9,
      encode: (input, level) => {
        let opts = { ..@fzip.DeflateOptions::default(), level, }
        of_fixed(@fzip.deflate_sync(fixed(input), opts~))
      },
    },
  ]
}
