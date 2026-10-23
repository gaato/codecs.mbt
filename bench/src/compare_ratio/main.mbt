///|
/// usage: compare_ratio --list <brotli|deflate>
///        compare_ratio <brotli|deflate> <min ms per measurement> <file>...
/// Prints, for each encoder, level and file: the encoder, `default` or
/// `max`, the level, the file, its size, the stream's size and MB/s (the
/// mean over at least the given time and 2 runs; 0 skips timing), and
/// whether gaato/brotli or gaato/deflate decodes the stream back to the
/// file, tab-separated. With the environment variable
/// ONLY, only the encoder of that name runs; with DUMP, each
/// stream is also written to that directory.
fn main {
  let args = @env.args()
  if args.get(1) == Some("--list") {
    let list = if args.get(2) == Some("brotli") {
      @compare.brotli_compress()
    } else {
      @compare.deflate_compress()
    }
    for e in list {
      println(e.name)
    }
    return
  }
  let format = args[1]
  let min_ms = @string.parse_int(args[2]) catch { _ => fail_with("bad time") }
  let encoders = match format {
    "brotli" => @compare.brotli_compress()
    "deflate" => @compare.deflate_compress()
    _ => fail_with("unknown format \{format}")
  }
  let only = @env.get_env_var("ONLY").unwrap_or("")
  // With DUMP set, each stream is also written there, for the reference
  // decoder to check.
  let dump = @env.get_env_var("DUMP").unwrap_or("")
  for e in encoders {
    if only != "" && e.name != only {
      continue
    }
    let levels = if e.default_level == e.max_level {
      [("default", e.default_level)]
    } else {
      [("default", e.default_level), ("max", e.max_level)]
    }
    for named in levels {
      let (which, level) = named
      for path in args[3:] {
        let input = @fs.read_file_to_bytes(path) catch {
          _ => fail_with("cannot read \{path}")
        }
        let encode = e.encode
        let stream = encode(input, level) catch {
          err => fail_with("\{e.name} \{path}: \{err}")
        }
        if dump != "" {
          let base = path.split("/").last().unwrap_or("")
          let tag = e.name
            .replace_all(old="/", new="_")
            .replace_all(old=" ", new="_")
          @fs.write_bytes_to_file("\{dump}/\{tag}-\{which}-\{base}", stream) catch {
            _ => fail_with("cannot write to \{dump}")
          }
        }
        // gaato/brotli and gaato/deflate say whether the stream decodes back.
        let back = try {
          match format {
            "brotli" => @brotli.decompress(stream)
            _ => @deflate.decompress(stream)
          }
        } catch {
          _ => b""
        }
        let checked = if back == input {
          "decodes back"
        } else if back.length() == 0 && input.length() > 0 {
          "does not decode"
        } else {
          "decodes to other bytes"
        }
        let mut speed = 0.0
        if min_ms > 0 {
          let mut spent = 0.0
          let mut runs = 0
          while runs < 2 || spent < min_ms.to_double() {
            let t0 = @env.now()
            ignore(
              encode(input, level) catch {
                _ => fail_with("the encoder failed")
              },
            )
            spent += (@env.now() - t0).to_double()
            runs += 1
          }
          speed = input.length().to_double() /
            (spent / runs.to_double() / 1000.0) /
            1.0e6
        }
        println(
          "\{e.name}\t\{which}\t\{level}\t\{path}\t\{input.length()}\t\{stream.length()}\t\{speed}\t\{checked}",
        )
      }
    }
  }
}

///|
/// Says why on stderr (an abort's message does not reach it), then aborts.
fn[T] fail_with(message : String) -> T {
  eprintln(message)
  abort(message)
}
