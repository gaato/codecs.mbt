///|
/// A case: its format, input, what the reference made of it
/// (`ok <sha256>`, `err`, or `any <sha256>` for a stream reported without a
/// verdict), and for the zlib streams with a preset dictionary, the
/// dictionary.
struct Case {
  format : String
  input : String
  expect : String
  dictionary : String
}

///|
/// The cases of `cases.tsv` in `dir`.
fn cases(dir : String) -> Array[Case] raise {
  let text = @fs.read_file_to_string("\{dir}/cases.tsv")
  let out = []
  for line in text.split("\n") {
    if line.is_empty() {
      continue
    }
    let f = line.split("\t").map(s => s.to_owned()).collect()
    out.push({
      format: f[0],
      input: f[2],
      expect: f[3],
      dictionary: f.get(4).unwrap_or(""),
    })
  }
  out
}

///|
/// The names of the decoders of a format.
fn decoders(format : String) -> Array[String] {
  match format {
    "zstd" => @compare.zstd_whole().map(d => d.name)
    "brotli" | "brotli-large" => @compare.brotli_whole().map(d => d.name)
    "deflate" => @compare.deflate_whole().map(d => d.name)
    "zlib" => @compare.zlib_whole().map(d => d.name)
    "zlib-dict" => @compare.zlib_dictionary().map(d => d.0)
    "gzip" => [..@compare.gzip_whole().map(d => d.name), @compare_async.name]
    _ => []
  }
}

///|
/// Whether the decoder `name` of `format` takes its input in pieces.
fn streams(format : String, name : String) -> Bool {
  let list = match format {
    "zstd" => @compare.zstd_pieces()
    "brotli" => @compare.brotli_pieces()
    "deflate" => @compare.deflate_pieces()
    "zlib" => @compare.zlib_pieces()
    "gzip" => @compare.gzip_pieces()
    _ => []
  }
  list.iter().any(d => d.name == name) ||
  (format == "gzip" && name == @compare_async.name)
}

///|
/// Decodes `input` with the decoder `name` of `format`.
async fn decode(
  format : String,
  name : String,
  input : Bytes,
  dictionary : Bytes,
) -> Bytes {
  if format == "zlib-dict" {
    for d in @compare.zlib_dictionary() {
      if d.0 == name {
        return (d.1)(input, dictionary)
      }
    }
  }
  if format == "gzip" && name == @compare_async.name {
    return @compare_async.gunzip_whole(input)
  }
  let list = match format {
    "zstd" => @compare.zstd_whole()
    "brotli" | "brotli-large" => @compare.brotli_whole()
    "deflate" => @compare.deflate_whole()
    "zlib" => @compare.zlib_whole()
    _ => @compare.gzip_whole()
  }
  for d in list {
    if d.name == name {
      return (d.decode)(input)
    }
  }
  fail("no decoder \{name} for \{format}")
}

///|
/// The decoder `name` of `format` fed in pieces of `piece` bytes, with an
/// output buffer of `out` bytes where it writes into the caller's.
async fn decode_pieces(
  format : String,
  name : String,
  input : Bytes,
  piece : Int32,
  out : Int32,
) -> Bytes {
  let buffer = Buffer()
  let sink = (v : BytesView) => buffer.write_bytesview(v)
  if format == "gzip" && name == @compare_async.name {
    @compare_async.gunzip(input, piece, out, sink)
    return buffer.to_bytes()
  }
  let list = match format {
    "zstd" => @compare.zstd_pieces()
    "brotli" | "brotli-large" => @compare.brotli_pieces()
    "deflate" => @compare.deflate_pieces()
    "zlib" => @compare.zlib_pieces()
    "gzip" => @compare.gzip_pieces()
    _ => []
  }
  guard list.search_by(d => d.name == name) is Some(i) else {
    fail("no streaming decoder \{name} for \{format}")
  }
  (list[i].run)(input, piece, out, sink)
  buffer.to_bytes()
}

///|
/// One line, with tabs and newlines turned into spaces, at most 120
/// characters.
fn one_line(s : String) -> String {
  let t = s.replace_all(old="\t", new=" ").replace_all(old="\n", new=" ")
  if t.length() > 120 {
    t[:120].to_owned()
  } else {
    t
  }
}

///|
/// usage: compare_check --list
///        compare_check <dir> <format> <decoder> <first case> [<end> [<piece> <out> [all]]]
/// With `piece` and `out`, the decoder takes its input `piece` bytes at a
/// time and writes into a buffer of `out` bytes (if it writes into the
/// caller's), over the valid cases only, or over every case with `all`.
/// Writes to stderr, which is not buffered, so that the lines before an
/// abort reach the script: `S <i>` before case i, then
/// `R <i> <pass|fail|note> <what the decoder did>`, and `E` at the end.
async fn main {
  let args = @env.args()
  if args.get(1) == Some("--list") {
    for format in ["zstd", "brotli", "deflate", "zlib", "zlib-dict", "gzip"] {
      for name in decoders(format) {
        println("\{format}\t\{name}\t\{streams(format, name)}")
      }
    }
    return
  }
  let dir = args[1]
  let format = args[2]
  let name = args[3]
  let first = @string.parse_int(args[4])
  let all = cases(dir)
  let end = match args.get(5) {
    Some(e) => @string.parse_int(e).min(all.length())
    None => all.length()
  }
  let pieces = match (args.get(6), args.get(7)) {
    (Some(p), Some(o)) => Some((@string.parse_int(p), @string.parse_int(o)))
    _ => None
  }
  let every = args.get(8) == Some("all")
  for i in first..<end {
    let c = all[i]
    if c.format != format && !(format == "brotli" && c.format == "brotli-large") {
      continue
    }
    if pieces is Some(_) && !every && !c.expect.has_prefix("ok") {
      continue
    }
    eprintln("S\t\{i}")
    let input = @fs.read_file_to_bytes("\{dir}/\{c.input}")
    let dictionary = if c.dictionary.is_empty() {
      b""
    } else {
      @fs.read_file_to_bytes("\{dir}/\{c.dictionary}")
    }
    let outcome = try {
      match pieces {
        Some((piece, out)) => decode_pieces(c.format, name, input, piece, out)
        None => decode(c.format, name, input, dictionary)
      }
    } catch {
      e => Err(one_line(e.to_string()))
    } noraise {
      out => Ok(out)
    }
    let (verdict, what) = match (c.expect.split(" ").collect(), outcome) {
      ([kind, sha], Ok(out)) => {
        let got = @codec_harness.sha256(out[:])
        let v = if kind == "any" {
          "note"
        } else if got == sha.to_owned() {
          "pass"
        } else {
          "fail"
        }
        let w = if got == sha.to_owned() { "decoded" } else { "differs" }
        (v, "\{w} \{out.length()}")
      }
      (fields, Err(msg)) => {
        let kind = fields.get(0).unwrap_or("").to_owned()
        (
          if kind == "err" {
            "pass"
          } else if kind == "any" {
            "note"
          } else {
            "fail"
          },
          "refused \{msg}",
        )
      }
      (_, Ok(out)) => ("fail", "accepted \{out.length()}")
    }
    eprintln("R\t\{i}\t\{verdict}\t\{what}")
  }
  eprintln("E")
}
