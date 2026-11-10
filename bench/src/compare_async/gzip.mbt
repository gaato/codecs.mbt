///|
/// The package and its version.
pub let name : String = "moonbitlang/core/async (MoonBit 0.10.20)"

///|
/// A reader over bytes in memory that hands out at most `piece` bytes per
/// read.
priv struct Source {
  data : Bytes
  piece : Int32
  mut pos : Int32
  controller : @io.BinaryReaderController
}

///|
impl @io.BinaryReaderImpl for Source with fn get_controller(self) {
  self.controller
}

///|
impl @io.BinaryReaderImpl for Source with fn raw_read_impl(
  self,
  dst,
  offset~,
  max_len~,
) {
  let n = max_len.min(self.piece).min(self.data.length() - self.pos)
  for i in 0..<n {
    dst[offset + i] = self.data[self.pos + i]
  }
  self.pos += n
  @compare.fed.val = self.pos
  n
}

///|
impl @io.BinaryReader for Source

///|
/// A writer that keeps what it is given.
priv struct Sink {
  out : Buffer
  controller : @io.BinaryWriterController
}

///|
impl @io.BinaryWriterImpl for Sink with fn get_controller(self) {
  self.controller
}

///|
impl @io.BinaryWriterImpl for Sink with fn raw_write_impl(
  self,
  data,
  offset~,
  len~,
) {
  self.out.write_bytesview(data[offset:offset + len])
  len
}

///|
impl @io.BinaryWriter for Sink

///|
/// Decodes the gzip `input`, read `piece` bytes at a time, into a buffer of
/// `out` bytes, handing each read to `sink`.
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
    controller: @io.BinaryReaderController(),
  })
  let buf = FixedArray::make(out, b'\x00')
  for ;; {
    let n = decoder.read_into(buf, offset=0, max_len=out)
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
  let sink = { out: Buffer(), controller: @io.BinaryWriterController(), }
  let encoder = @agzip.Encoder(sink)
  encoder.write(input[:])
  encoder.end()
  sink.out.to_bytes()
}
