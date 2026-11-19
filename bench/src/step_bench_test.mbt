// What a call of `step` costs when the input comes in small pieces: every
// streaming decoder and encoder over the first 64 KiB of the benchmarks'
// text, fed 1 and 16 bytes at a time into a 64 KiB buffer. The whole-input
// benchmarks above hide this cost; a reader of a socket or a pipe pays it.
// The streams are each format's own encoder's: what is measured is the
// per-call work, not one stream or another.

///|
/// The first 64 KiB of the benchmarks' text.
fn step_text() -> Bytes {
  let text = @brotli.decompress(decode64(brotli_text)) catch {
    _ => abort("brotli: bad stream")
  }
  text[:65536].to_owned()
}

///|
/// Decodes `input` fed `piece` bytes at a time into `out`, after a reset;
/// returns how many bytes came out.
fn[D : @codec_bytes.Decode] decode_in_pieces(
  decoder : D,
  input : Bytes,
  piece : Int32,
  out : FixedArray[Byte],
) -> Int32 {
  decoder.reset()
  let mut pos = 0
  let mut total = 0
  for ;; {
    let end = (pos + piece).min(input.length())
    let last = end == input.length()
    let mut rest = input[pos:end]
    for ;; {
      let status = decoder.step(rest, out.mut_view(), end=last) catch {
        _ => abort("bad stream")
      }
      rest = rest[decoder.last_consumed():]
      total += decoder.last_produced()
      match status {
        Done => return total
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
    pos = end
  }
}

///|
/// Encodes `input` fed `piece` bytes at a time into `out`, after a reset,
/// finishing with the last piece; returns how many bytes came out.
fn[E : @codec_bytes.Encode] encode_in_pieces(
  encoder : E,
  input : Bytes,
  piece : Int32,
  out : FixedArray[Byte],
) -> Int32 {
  encoder.reset()
  let mut pos = 0
  let mut total = 0
  for ;; {
    let end = (pos + piece).min(input.length())
    let action : @codec_bytes.EncodeAction = if end == input.length() {
      Finish
    } else {
      Continue
    }
    let mut rest = input[pos:end]
    for ;; {
      let status = encoder.step(rest, out.mut_view(), action~) catch {
        _ => abort("encoder raised")
      }
      rest = rest[encoder.last_consumed():]
      total += encoder.last_produced()
      match status {
        Done => return total
        NeedMoreInput => break
        NeedMoreOutput => ()
      }
    }
    pos = end
  }
}

///|
/// Adds the 1- and 16-byte benchmarks of a decoder, after checking that it
/// gives `size` bytes back.
fn[D : @codec_bytes.Decode] bench_decode_pieces(
  b : @bench.T,
  name : String,
  decoder : D,
  stream : Bytes,
  size : Int32,
  out : FixedArray[Byte],
) -> Unit {
  for piece in [1, 16] {
    assert_eq(decode_in_pieces(decoder, stream, piece, out), size) catch {
      _ => abort("\{name}: wrong size in \{piece}-byte pieces")
    }
    b.bench(name="\{name} decode, \{piece}-byte pieces", () => {
      b.keep(decode_in_pieces(decoder, stream, piece, out))
    })
  }
}

///|
/// Adds the 1- and 16-byte benchmarks of an encoder.
fn[E : @codec_bytes.Encode] bench_encode_pieces(
  b : @bench.T,
  name : String,
  encoder : E,
  input : Bytes,
  out : FixedArray[Byte],
) -> Unit {
  for piece in [1, 16] {
    b.bench(name="\{name} encode, \{piece}-byte pieces", () => {
      b.keep(encode_in_pieces(encoder, input, piece, out))
    })
  }
}

///|
test "decode in small pieces" (b : @bench.T) {
  let text = step_text()
  let n = text.length()
  let out = FixedArray::make(1 << 16, b'\x00')
  let unix = @lzw.Format::unix_compress() catch { _ => abort("lzw") }
  let lzw_stream = @lzw.compress(text, unix) catch { _ => abort("lzw") }
  bench_decode_pieces(b, "zstd", @zstd.Decoder(), @zstd.compress(text), n, out)
  bench_decode_pieces(
    b,
    "brotli",
    @brotli.Decoder(),
    @brotli.compress(text),
    n,
    out,
  )
  bench_decode_pieces(
    b,
    "deflate",
    @deflate.Decoder(),
    @deflate.compress(text),
    n,
    out,
  )
  bench_decode_pieces(b, "zlib", @zlib.Decoder(), @zlib.compress(text), n, out)
  bench_decode_pieces(b, "gzip", @gzip.Decoder(), @gzip.compress(text), n, out)
  bench_decode_pieces(
    b,
    "snappy",
    @snappy.Decoder(),
    @snappy.compress(text),
    n,
    out,
  )
  bench_decode_pieces(b, "lz4", @lz4.Decoder(), @lz4.compress(text), n, out)
  bench_decode_pieces(b, "lzw", @lzw.Decoder(unix), lzw_stream, n, out)
}

///|
test "encode in small pieces" (b : @bench.T) {
  let text = step_text()
  let out = FixedArray::make(1 << 16, b'\x00')
  let unix = @lzw.Format::unix_compress() catch { _ => abort("lzw") }
  bench_encode_pieces(b, "zstd", @zstd.Encoder(), text, out)
  bench_encode_pieces(b, "brotli", @brotli.Encoder(), text, out)
  bench_encode_pieces(b, "deflate", @deflate.Encoder(), text, out)
  bench_encode_pieces(b, "zlib", @zlib.Encoder(), text, out)
  bench_encode_pieces(b, "gzip", @gzip.Encoder(), text, out)
  bench_encode_pieces(b, "snappy", @snappy.Encoder(), text, out)
  bench_encode_pieces(b, "lz4", @lz4.Encoder(), text, out)
  bench_encode_pieces(b, "lzw", @lzw.Encoder(unix), text, out)
}
