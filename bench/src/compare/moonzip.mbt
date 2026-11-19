// moonbitstack/moonzip: one package per format. Its one-shot calls take a
// view and return the whole output; its streaming `Reader` takes a piece
// and returns what it decoded, and `finish` the rest at the end of the
// input. No `limit` is passed: the other packages are called without one.

///|
let moonzip_name : String = "moonbitstack/moonzip 0.4.1"

///|
/// Feeds `input` in pieces to a moonzip `Reader`, given as its `push` and
/// `finish`.
fn moonzip_run(
  push : (BytesView) -> Bytes raise,
  finish : () -> Bytes raise,
  input : Bytes,
  piece : Int32,
  sink : (BytesView) -> Unit,
) -> Unit raise {
  each_piece(input, piece, (chunk, last) => {
    sink(push(chunk)[:])
    if last {
      sink(finish()[:])
    }
  })
}

///|
fn moonzip_zstd_whole() -> Whole {
  { name: moonzip_name, decode: input => @mz_zstd.unzstd(input[:]), }
}

///|
fn moonzip_zstd_pieces() -> Pieces {
  {
    name: moonzip_name,
    caller_buffer: false,
    run: (input, piece, _, sink) => {
      let r = @mz_zstd.Reader::new()
      moonzip_run(c => r.push(c), () => r.finish(), input, piece, sink)
    },
  }
}

///|
/// moonzip's zstd encoder walks a deeper chain up to level 9 and the same
/// one from 10 on; 22 is given as its highest, as gaato/zstd's.
fn moonzip_zstd_compress() -> Compress {
  {
    name: moonzip_name,
    default_level: 3,
    max_level: 22,
    encode: (input, level) => @mz_zstd.zstd(input[:], level~),
  }
}

///|
fn moonzip_brotli_whole() -> Whole {
  { name: moonzip_name, decode: input => @mz_brotli.unbrotli(input[:]), }
}

///|
fn moonzip_brotli_pieces() -> Pieces {
  {
    name: moonzip_name,
    caller_buffer: false,
    run: (input, piece, _, sink) => {
      let r = @mz_brotli.Reader::new()
      moonzip_run(c => r.push(c), () => r.finish(), input, piece, sink)
    },
  }
}

///|
fn moonzip_brotli_compress() -> Compress {
  {
    name: moonzip_name,
    default_level: 9,
    max_level: 11,
    encode: (input, quality) => @mz_brotli.brotli(input[:], quality~),
  }
}

///|
fn moonzip_deflate_whole() -> Whole {
  { name: moonzip_name, decode: input => @mz_deflate.inflate(input[:]), }
}

///|
fn moonzip_zlib_whole() -> Whole {
  { name: moonzip_name, decode: input => @mz_zlib.unzlib(input[:]), }
}

///|
fn moonzip_gzip_whole() -> Whole {
  { name: moonzip_name, decode: input => @mz_gzip.gunzip(input[:]), }
}

///|
fn moonzip_deflate_pieces() -> Pieces {
  {
    name: moonzip_name,
    caller_buffer: false,
    run: (input, piece, _, sink) => {
      let r = @mz_deflate.Reader::new()
      moonzip_run(c => r.push(c), () => r.finish(), input, piece, sink)
    },
  }
}

///|
fn moonzip_zlib_pieces() -> Pieces {
  {
    name: moonzip_name,
    caller_buffer: false,
    run: (input, piece, _, sink) => {
      let r = @mz_zlib.Reader::new()
      moonzip_run(c => r.push(c), () => r.finish(), input, piece, sink)
    },
  }
}

///|
fn moonzip_gzip_pieces() -> Pieces {
  {
    name: moonzip_name,
    caller_buffer: false,
    run: (input, piece, _, sink) => {
      let r = @mz_gzip.Reader::new()
      moonzip_run(c => r.push(c), () => r.finish(), input, piece, sink)
    },
  }
}

///|
fn moonzip_deflate_compress() -> Compress {
  {
    name: moonzip_name,
    default_level: 6,
    max_level: 9,
    encode: (input, level) => @mz_deflate.deflate(input[:], level~),
  }
}
