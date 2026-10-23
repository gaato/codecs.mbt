///|
/// A source that hands out at most `piece` bytes per read, for the
/// pull-style decoders of gmlewis/flate, gzip and zlib.
priv struct Trickle {
  data : Bytes
  piece : Int32
  mut pos : Int32
}

///|
fn Trickle::new(data : Bytes, piece : Int32) -> Trickle {
  { data, piece, pos: 0, }
}

///|
impl @gm_flate.Reader for Trickle with fn read(self, b) {
  if self.pos >= self.data.length() {
    return (0, Some(@gm_io.eof))
  }
  let n = b.length().min(self.piece).min(self.data.length() - self.pos)
  for i in 0..<n {
    b[i] = self.data[self.pos + i]
  }
  self.pos += n
  fed.val = self.pos
  (n, None)
}

///|
impl @gm_flate.Reader for Trickle with fn read_byte(self) {
  if self.pos >= self.data.length() {
    return (b'\x00', Some(@gm_io.eof))
  }
  let b = self.data[self.pos]
  self.pos += 1
  fed.val = self.pos
  (b, None)
}

///|
/// Reads `r` to its end through a buffer of `out` bytes, handing each read
/// to `sink`.
fn gm_drain(
  read : (@gm_io.Slice[Byte]) -> (Int32, @gm_io.IOError?),
  out : Int32,
  sink : (BytesView) -> Unit,
) -> Unit raise {
  let buf = @gm_io.Slice::new(Array::make(out, b'\x00'))
  for ;; {
    let (n, err) = read(buf)
    if n > 0 {
      sink(Bytes::from_array(buf.as_array_view()[:n])[:])
    }
    match err {
      None => ()
      Some(e) => if e == @gm_io.eof { return } else { raise e }
    }
  }
}

///|
/// gmlewis/flate's raw DEFLATE decoder over `src`.
fn gm_inflate(
  src : Trickle,
  out : Int32,
  sink : (BytesView) -> Unit,
) -> Unit raise {
  let d = &@gm_flate.Reader::new(src)
  gm_drain(b => d.read(b), out, sink)
}

///|
/// gmlewis/zlib's decoder over `src`.
fn gm_unzlib(
  src : Trickle,
  out : Int32,
  sink : (BytesView) -> Unit,
) -> Unit raise {
  let (r, err) = @gm_zlib.Reader::new(src)
  check_io(err)
  gm_drain(b => @gm_io.Reader::read(r, b), out, sink)
}

///|
/// gmlewis/gzip's decoder over `src`.
fn gm_gunzip(
  src : Trickle,
  out : Int32,
  sink : (BytesView) -> Unit,
) -> Unit raise {
  let (r, err) = @gm_gzip.Reader::new(src)
  check_io(err)
  gm_drain(b => r.read(b), out, sink)
}

///|
/// Collects what `run` hands its sink.
fn collect(run : ((BytesView) -> Unit) -> Unit raise) -> Bytes raise {
  let out = Buffer()
  run(v => out.write_bytesview(v))
  out.to_bytes()
}

///|
/// gmlewis's encoders write to an `io.Buffer`: `make` wraps it in one.
fn gm_compress(
  input : Bytes,
  make : (@gm_io.Buffer) -> (
    (@gm_io.Slice[Byte]) -> (Int32, @gm_io.IOError?),
    () -> @gm_io.IOError?,
  ),
) -> Bytes raise {
  let dst = @gm_io.Buffer::new()
  let (write, close) = make(dst)
  let (_, err) = write(@gm_io.Slice::new(input.to_array()))
  check_io(err)
  check_io(close())
  dst.to_bytes()
}
