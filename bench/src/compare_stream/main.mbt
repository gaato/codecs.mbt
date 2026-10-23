///|
/// The decoders of a format, in pieces and whole.
fn decoders(format : String) -> (Array[@compare.Pieces], Array[@compare.Whole]) {
  match format {
    "zstd" => (@compare.zstd_pieces(), @compare.zstd_whole())
    "brotli" => (@compare.brotli_pieces(), @compare.brotli_whole())
    "deflate" => (@compare.deflate_pieces(), @compare.deflate_whole())
    "zlib" => (@compare.zlib_pieces(), @compare.zlib_whole())
    "gzip" => (@compare.gzip_pieces(), @compare.gzip_whole())
    _ => abort("unknown format \{format}")
  }
}

///|
/// usage: compare_stream --list
///        compare_stream <format> <decoder> <file> <piece> <out>
/// `piece` 0 decodes the file whole, with the decoder's one-shot call;
/// otherwise the input goes in `piece` bytes at a time and the output comes
/// out through a buffer of `out` bytes (for the decoders that write into the
/// caller's). Prints, tab-separated: the bytes out, the bytes out before the
/// second half of the input went in, the FNV-1a hash of the output, and the
/// milliseconds taken. With the environment variable REPEAT=n, the decode
/// runs n times and the time is their mean. A decoder that raises prints
/// `refused`, the bytes out until then and its error, and exits normally, so
/// that a refusal is told apart from an abort (whose message may not reach
/// the caller) and its peak memory is still measured.
async fn main {
  let args = @env.args()
  if args.get(1) == Some("--list") {
    for format in ["zstd", "brotli", "deflate", "zlib", "gzip"] {
      let (pieces, whole) = decoders(format)
      for d in whole {
        let streams = pieces.iter().any(p => p.name == d.name)
        println("\{format}\t\{d.name}\t\{streams}")
      }
    }
    println("gzip\t\{@compare_async.name}\ttrue")
    return
  }
  let format = args[1]
  let name = args[2]
  let input = @fs.read_file_to_bytes(args[3]) catch {
    _ => abort("cannot read \{args[3]}")
  }
  let piece = @string.parse_int(args[4]) catch { _ => abort("bad piece") }
  let out = @string.parse_int(args[5]) catch { _ => abort("bad out") }
  let (pieces, whole) = decoders(format)
  let mut total = 0
  let mut early = 0
  let mut hash : UInt32 = 2166136261
  let half = input.length() / 2
  let sink = (v : BytesView) => {
    for b in v {
      hash = (hash ^ b.to_uint()) * 16777619
    }
    total += v.length()
  }
  let repeat = @string.parse_int(@env.get_env_var("REPEAT").unwrap_or("1")) catch {
    _ => 1
  }
  let async_gzip = format == "gzip" && name == @compare_async.name
  let t0 = @env.now()
  let refused = (e : Error) => {
    println(
      "refused\t\{total}\t\{e.to_string().replace_all(old="\t", new=" ").replace_all(old="\n", new=" ")}",
    )
  }
  for _ in 0..<repeat {
    total = 0
    early = 0
    hash = 2166136261
    if piece == 0 && async_gzip {
      let output = @compare_async.gunzip_whole(input) catch {
        e => {
          refused(e)
          return
        }
      }
      sink(output[:])
    } else if piece == 0 {
      guard whole.search_by(d => d.name == name) is Some(i) else {
        abort("no decoder \{name}")
      }
      let output = (whole[i].decode)(input) catch {
        e => {
          refused(e)
          return
        }
      }
      sink(output[:])
    } else {
      // What came out while the first half was all that had gone in.
      let counting = (v : BytesView) => {
        sink(v)
        if @compare.fed.val <= half {
          early = total
        }
      }
      if async_gzip {
        @compare_async.gunzip(input, piece, out, counting) catch {
          e => {
            refused(e)
            return
          }
        }
      } else {
        guard pieces.search_by(d => d.name == name) is Some(i) else {
          abort("no streaming decoder \{name}")
        }
        (pieces[i].run)(input, piece, out, counting) catch {
          e => {
            refused(e)
            return
          }
        }
      }
    }
  }
  let ms = (@env.now() - t0).to_double() / repeat.to_double()
  println("\{total}\t\{early}\t\{hash}\t\{ms}")
}
