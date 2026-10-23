///|
/// The package and its version.
pub let name : String = "moonbitlang/async 0.22.5"

///|
/// A reader over bytes in memory that hands out at most `piece` bytes per
/// read.
#warnings("-alert_internal")
priv struct Source {
  data : Bytes
  piece : Int32
  mut pos : Int32
  buffer : @aio.ReaderBuffer
}

///|
#warnings("-alert_internal")
impl @aio.Reader for Source with fn _get_internal_buffer(self) {
  self.buffer
}

///|
#warnings("-alert_internal")
impl @aio.Reader for Source with fn _direct_read(self, dst, offset~, max_len~) {
  let n = max_len.min(self.piece).min(self.data.length() - self.pos)
  for i in 0..<n {
    dst[offset + i] = self.data[self.pos + i]
  }
  self.pos += n
  @compare.fed.val = self.pos
  n
}

///|
/// A writer that keeps what it is given.
priv struct Sink {
  out : Buffer
}

///|
impl @aio.Writer for Sink with fn write_once(self, data, offset~, len~) {
  self.out.write_bytesview(data[offset:offset + len])
  len
}

///|
/// Decodes the gzip `input`, read `piece` bytes at a time, into a buffer of
/// `out` bytes, handing each read to `sink`.
#warnings("-alert_internal")
pub async fn gunzip(
  input : Bytes,
  piece : Int32,
  out : Int32,
  sink : (BytesView) -> Unit,
) -> Unit {
  let decoder = @agzip.Decoder({
    data: input,
    piece,
    pos: 0,
    buffer: @aio.ReaderBuffer::new(),
  })
  let buf = FixedArray::make(out, b'\x00')
  for ;; {
    let n = decoder.read(buf, offset=0, max_len=out)
    if n == 0 {
      return
    }
    sink(Bytes::from_array(buf[:n])[:])
  }
}

///|
/// Decodes the whole gzip `input`.
pub async fn gunzip_whole(input : Bytes) -> Bytes {
  let out = Buffer()
  gunzip(input, 1 << 30, 1 << 16, v => out.write_bytesview(v))
  out.to_bytes()
}

///|
/// Compresses `input` into one gzip member.
pub async fn gzip(input : Bytes) -> Bytes {
  let sink = { out: Buffer(), }
  let encoder = @agzip.Encoder(sink)
  encoder.write(input)
  encoder.end()
  sink.out.to_bytes()
}
