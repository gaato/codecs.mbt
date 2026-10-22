///|
/// gaato/png's streaming decoder over the file at `path`, read in 64 KiB
/// pieces: what it gave, or why it refused the file.
async fn gaato_stream(path : String) -> String {
  let file = @afs.open(path, mode=ReadOnly)
  defer file.close()
  let decoder = @png.Decoder()
  let input = FixedArray::make(1 << 16, b'\x00')
  let out = FixedArray::make(1 << 16, b'\x00')
  let mut start = 0
  let mut end = 0
  let mut eof = false
  let mut total = 0L
  for ;; {
    if start == end && !eof {
      start = 0
      end = file.read(input)
      eof = end == 0
    }
    let view = Bytes::from_array(input[start:end])
    let status = decoder.step_into(view, out, end=eof) catch {
      e => return "refused \{@debug.to_string(e)}"
    }
    start += decoder.last_consumed()
    total += decoder.last_produced().to_int64()
    match status {
      Done =>
        return "\{decoder.width()}x\{decoder.height()}, \{total} bytes of rows"
      NeedMoreInput =>
        if !eof {
          // Keep what is left and read more after it.
          let left = end - start
          input.blit_to(input, len=left, src_offset=start, dst_offset=0)
          start = 0
          end = left
          let n = file.read(input, offset=left)
          eof = n == 0
          end += n
        }
      _ => ()
    }
  }
}

///|
/// usage: memory DECODER FILE [MAX_OUTPUT], DECODER one of gaato-stream,
/// gaato-decode, typst, gmlewis, mizchi, read or none; MAX_OUTPUT is
/// gaato-decode's `max_output`, its default if left out. Prints the image's
/// size, or `refused` and the message.
async fn main {
  let args = @env.args()
  guard args.length() == 3 || args.length() == 4 else {
    abort("usage: memory DECODER FILE [MAX_OUTPUT]")
  }
  let decoder = args[1]
  let path = args[2]
  match decoder {
    "none" => println("nothing")
    "gaato-stream" => println(gaato_stream(path))
    _ => {
      let data = @afs.read_file(path).binary()
      match decoder {
        "read" => println("\{data.length()} bytes read")
        "gaato-decode" => {
          let max_output = if args.length() == 4 {
            @string.parse_int(args[3]) catch {
              _ => abort("MAX_OUTPUT")
            }
          } else {
            536_870_912
          }
          let image = @png.decode(data, max_output~) catch {
            e => {
              println("refused \{@debug.to_string(e)}")
              return
            }
          }
          println(
            "\{image.width}x\{image.height}, \{image.pixels.length()} bytes",
          )
        }
        _ => {
          // compare_png's adapters bring the image to RGBA16, which would
          // double what is measured: decode with each package's own call.
          let (w, h, n) = @compare_png.decode_native(decoder, data) catch {
            @compare_png.Refused(message) => {
              println("refused \{message}")
              return
            }
          }
          println("\{w}x\{h}, \{n} bytes")
        }
      }
    }
  }
}
