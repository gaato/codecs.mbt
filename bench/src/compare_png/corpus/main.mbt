///|
/// The seeds of `path`: a `=== name` line before each one's base64 lines, as
/// png_corpus reads them.
fn seeds_of(path : String) -> Array[(String, Bytes)] raise {
  let seeds = []
  let mut name = ""
  let b64 = StringBuilder()
  fn flush() raise {
    if name != "" {
      seeds.push((name, @base64.decode(b64.to_string())))
    }
    b64.reset()
  }

  for line in @fs.read_file_to_string(path).split("\n") {
    match line.strip_prefix("=== ") {
      Some(rest) => {
        flush()
        name = rest.to_owned()
      }
      None => b64.write_string(line.trim().to_owned())
    }
  }
  flush()
  seeds
}

///|
/// A case: its label, its bytes, and whether it is a valid image whose
/// pixels must be gaato/png's (PngSuite's images but the x ones, and the
/// APNG vectors, whose default image is compared).
priv struct Case {
  label : String
  data : Bytes
  valid : Bool
}

///|
/// The regular files of `dir`, sorted by name.
fn files_of(dir : String) -> Array[String] {
  let names = (@fs.read_dir(dir) catch {
    e => abort("\{dir}: \{@debug.to_string(e)}")
  }).to_owned()
  names.sort()
  names.filter(name => @fs.is_file("\{dir}/\{name}") catch { _ => false })
}

///|
fn read(path : String) -> Bytes {
  @fs.read_file_to_bytes(path) catch {
    e => abort("\{path}: \{@debug.to_string(e)}")
  }
}

///|
/// `message` on one line, with its digits as `#`, so that messages that
/// differ only in a number are counted together.
fn without_digits(message : String) -> String {
  let out = StringBuilder()
  let mut space = false
  for c in message {
    if c == '\n' || c == ' ' || c == '\t' {
      space = true
      continue
    }
    if space {
      out.write_char(' ')
      space = false
    }
    out.write_char(if c >= '0' && c <= '9' { '#' } else { c })
  }
  out.to_string()
}

///|
/// What `decoder` makes of `case`. A valid case is `same` when its pixels
/// are those gaato/png gives, `other` when they are not; any case is
/// `refused` with the decoder's message. A broken case that the decoder
/// decodes is `decoded`, with whether gaato/png refuses it.
fn outcome(decoder : String, case : Case) -> String {
  let theirs = Ok(@compare_png.decode_with(decoder, case.data)) catch {
    Refused(message) => Err(message)
  }
  match theirs {
    Err(message) => "refused\t\{without_digits(message)}"
    Ok(image) => {
      // The reference is bounded, so that a file claiming a huge image
      // does not take down the run of another decoder.
      let ours = Some(@compare_png.gaato(case.data, max_output=1 << 28)) catch {
        _ => None
      }
      let verdict = match ours {
        _ if decoder == "gaato-stream" => "not compared"
        Some(want) if want.same(image) => "same"
        Some(want) if want.width != image.width || want.height != image.height =>
          "other size \{image.width}x\{image.height}, gaato \{want.width}x\{want.height}"
        Some(_) => "other pixels"
        None => "gaato refuses"
      }
      if case.valid {
        verdict
      } else {
        "decoded\t\{verdict}"
      }
    }
  }
}

///|
/// usage: corpus DECODER [--from N] [--only N] [--dump DIR] MODE ARGS...
///   suite DIR      PngSuite's files: the x ones broken, the others valid
///   apng PATH...   animated PNGs, valid: their default image is compared
///   seeds FILE     the damaged copies of png_corpus's seeds
///   files PATH...  broken files, or directories of them
/// Prints `<n>\t<label>\t<outcome>` on stderr for each case from `--from`
/// (or only case `--only`), and `done` after the last. With `--dump`, writes
/// each case to `DIR/<n>.png` instead and prints `<n>\t<label>`, so that a
/// decoder that hangs can be run on each case in a process of its own.
fn main {
  let args = @env.args()
  guard args.length() >= 3 else {
    abort("usage: corpus DECODER [--from N] [--only N] MODE ARGS...")
  }
  let decoder = args[1]
  guard @compare_png.decoders.contains(decoder) else {
    abort("no decoder \{decoder}")
  }
  let mut from = 0
  let mut only = -1
  let mut dump = None
  let mut i = 2
  while i + 1 < args.length() {
    match args[i] {
      "--from" =>
        from = @string.parse_int(args[i + 1]) catch { _ => abort("--from") }
      "--dump" => dump = Some(args[i + 1])
      "--only" =>
        only = @string.parse_int(args[i + 1]) catch { _ => abort("--only") }
      _ => break
    }
    i += 2
  }
  let mode = args[i]
  let rest = args[i + 1:]
  let cases : Array[Case] = []
  match mode {
    "suite" =>
      for dir in rest {
        for name in files_of(dir) {
          guard name.has_suffix(".png") else { continue }
          cases.push({
            label: name,
            data: read("\{dir}/\{name}"),
            valid: !name.has_prefix("x"),
          })
        }
      }
    "apng" | "files" =>
      for path in rest {
        let is_dir = @fs.is_dir(path) catch { _ => false }
        let paths = if is_dir {
          files_of(path).map(name => "\{path}/\{name}")
        } else {
          [path]
        }
        for file in paths {
          cases.push({ label: file, data: read(file), valid: mode == "apng", })
        }
      }
    "seeds" =>
      for path in rest {
        let seeds = seeds_of(path) catch { e => abort("\{path}: \{e}") }
        for index, seed in seeds {
          let (name, data) = seed
          for case in @damage.png_damage(data, index) {
            cases.push({
              label: "\{name} \{case.desc}",
              data: case.data,
              valid: false,
            })
          }
        }
      }
    _ => abort("no mode \{mode}")
  }
  for n, case in cases {
    if n < from || (only >= 0 && n != only) {
      continue
    }
    if dump is Some(dir) {
      @fs.write_bytes_to_file("\{dir}/\{n}.png", case.data) catch {
        e => abort("\{dir}: \{@debug.to_string(e)}")
      }
      eprintln("\{n}\t\{case.label}")
      continue
    }
    eprintln("\{n}\t\{case.label}\t\{outcome(decoder, case)}")
  }
  eprintln("done\t\{cases.length()}")
}
