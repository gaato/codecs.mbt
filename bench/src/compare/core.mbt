// moonbitlang/core's DEFLATE, zlib and gzip (compress/flate, compress/zlib,
// compress/gzip), the codecs that come with the toolchain. They are
// experimental packages: this package allows them in moon.pkg.

///|
/// The name the core codecs go by in the comparison. Core has no version of
/// its own: it is the toolchain's, `moonbit-version` at the repository root.
pub let core_name : String = "moonbitlang/core 0.10.20"

///|
/// Runs one of core's push decoders over `input` in pieces into a buffer of
/// `out` bytes. `check_end` is the gzip and zlib decoders' end-of-input
/// call; the raw decoder has none, and input that runs out before its final
/// block is a truncated stream. Input after the end of the stream is left
/// unread, as the other packages' streaming adapters leave it.
fn core_run(
  step : (BytesView, MutArrayView[Byte]) -> @core_flate.StepResult raise,
  check_end : (() -> @core_flate.Status raise)?,
  input : Bytes,
  piece : Int32,
  out : Int32,
  sink : (BytesView) -> Unit,
) -> Unit raise {
  let buf = FixedArray::make(out, b'\x00')
  let mut done = false
  each_piece(input, piece, (chunk, last) => {
    let mut rest = chunk
    while !done {
      let r = step(rest, buf.mut_view())
      rest = rest[r.consumed:]
      sink(Bytes::from_array(buf[:r.produced])[:])
      match r.status {
        Done => done = true
        NeedMoreOutput => ()
        NeedMoreInput =>
          // gzip and zlib may checksum output before they take more input;
          // what they did not take is offered again.
          if rest.length() == 0 {
            break
          } else if r.consumed == 0 && r.produced == 0 {
            abort("\{core_name}: no progress on \{rest.length()} bytes")
          }
      }
    }
    if done || !last {
      return
    }
    guard check_end is Some(check) else { fail("truncated stream") }
    while !done {
      match check() {
        Done => done = true
        NeedMoreOutput => {
          let r = step(b"", buf.mut_view())
          sink(Bytes::from_array(buf[:r.produced])[:])
          done = r.status is Done
        }
        NeedMoreInput => fail("truncated stream")
      }
    }
  })
}

///|
/// core's raw decoder over `IncrementalDecoder::step`, as the benchmarks
/// call gaato/deflate's `step_into`.
pub fn core_flate_steps(input : BytesView, out : FixedArray[Byte]) -> Int32 {
  let decoder = @core_flate.IncrementalDecoder()
  let mut rest = input
  let mut total = 0
  for ;; {
    let r = decoder.step(rest, out.mut_view()) catch {
      _ => abort("core flate: bad stream")
    }
    rest = rest[r.consumed:]
    total += r.produced
    match r.status {
      Done => return total
      NeedMoreOutput => ()
      NeedMoreInput => abort("core flate: truncated stream")
    }
  }
}

///|
fn core_raw_whole() -> Whole {
  { name: core_name, decode: input => @core_flate.inflate_exact(input), }
}

///|
fn core_zlib_whole() -> Whole {
  { name: core_name, decode: input => @core_zlib.decompress(input), }
}

///|
fn core_gzip_whole() -> Whole {
  { name: core_name, decode: input => @core_gzip.decompress(input), }
}

///|
fn core_zlib_dictionary() -> (String, (Bytes, Bytes) -> Bytes raise) {
  (core_name, (input, dict) => @core_zlib.decompress(input, dictionary=dict))
}

///|
fn core_raw_pieces() -> Pieces {
  {
    name: core_name,
    caller_buffer: true,
    run: (input, piece, out, sink) => {
      let d = @core_flate.IncrementalDecoder()
      core_run((i, o) => d.step(i, o), None, input, piece, out, sink)
    },
  }
}

///|
fn core_zlib_pieces() -> Pieces {
  {
    name: core_name,
    caller_buffer: true,
    run: (input, piece, out, sink) => {
      let d = @core_zlib.Decoder()
      core_run(
        (i, o) => d.step(i, o),
        Some(() => d.check_end()),
        input,
        piece,
        out,
        sink,
      )
    },
  }
}

///|
fn core_gzip_pieces() -> Pieces {
  {
    name: core_name,
    caller_buffer: true,
    run: (input, piece, out, sink) => {
      let d = @core_gzip.Decoder()
      core_run(
        (i, o) => d.step(i, o),
        Some(() => d.check_end()),
        input,
        piece,
        out,
        sink,
      )
    },
  }
}

///|
/// core's raw encoder at `Standard(level)`, 6 when no strategy is given. Its
/// `Split` and `Optimal` strategies are not measured.
fn core_raw_compress() -> Compress {
  {
    name: core_name,
    default_level: 6,
    max_level: 9,
    encode: (input, level) => {
      @core_flate.deflate_all(input, strategy=Standard(level~))
    },
  }
}
