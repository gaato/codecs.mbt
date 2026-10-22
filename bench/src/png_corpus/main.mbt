///|
/// The ancillary chunks a second run asks to have reported, so that their
/// blocks, and the second zlib decoder, are counted too.
let reported : Array[String] = [
  "tEXt", "zTXt", "iTXt", "iCCP", "eXIf", "tIME", "sPLT", "hIST",
]

///|
/// The samples a pixel of `color_type` has.
fn channels(color_type : @png.ColorType) -> Int32 {
  match color_type {
    Grayscale | IndexedColor => 1
    GrayscaleAlpha => 2
    Truecolor => 3
    TruecolorAlpha => 4
  }
}

///|
/// The name of an error's kind, with the resource of a limit.
fn kind_name(e : @codec.CodecError) -> String {
  match e.kind() {
    LimitExceeded(limit) => "LimitExceeded(\{@debug.to_string(limit.resource)})"
    kind => @debug.to_string(kind)
  }
}

///|
/// What the streaming decoder makes of `input`, given whole: `ok`, the kind
/// of its error, or what broke the contract. After every step its
/// `memory_usage` is checked against the formula of RESOURCE_BOUNDS.md: the
/// zlib decoder and the palette, two rows of the image's full width from the
/// step after `Header`, and with chunks to report a block of at most
/// `max_chunk_bytes` and the second zlib decoder.
fn stream(input : Bytes, report : Array[String]) -> String {
  let decoder = @png.Decoder(report~)
  let mut base = 47_360
  if !report.is_empty() {
    base += 46_592 + (1 << 20)
  }
  let mut rows = 0
  let mut out = FixedArray::make(1 << 16, b'\x00')
  let mut rest = input[:]
  for steps = 0; steps < 10_000_000; steps = steps + 1 {
    let status = decoder.step_into(rest, out, end=true) catch {
      e => return kind_name(e)
    }
    if decoder.memory_usage() > base + rows {
      return "memory \{decoder.memory_usage()} over \{base + rows}"
    }
    rest = rest[decoder.last_consumed():]
    match status {
      Done => return "ok"
      Header => {
        let bits = channels(decoder.color_type()) * decoder.bit_depth()
        let row = (decoder.width().to_int64() * bits.to_int64() + 7) / 8
        rows = 2 * (1 + row.min(1_000_000_000L).to_int())
      }
      NeedMoreOutput => out = FixedArray::make(decoder.room_needed(), b'\x00')
      NeedMoreInput => return "NeedMoreInput at the end of the input"
      _ => ()
    }
  }
  "no end after 10,000,000 steps"
}

///|
/// The image as typst's `decode_png` gives it: gaato/png's one-shot
/// `decode`, each row through its converter's `expanded`, and 16-bit samples
/// swapped to little-endian (as in conformance/src/png_test.mbt).
fn expand(input : Bytes) -> (@codecs.ColorType, Bytes) raise @codec.CodecError {
  let image = @png.decode(input)
  let converter = image.converter
  let channels = converter.expanded_channels()
  let depth = converter.expanded_depth()
  let per_row = image.width * channels * depth / 8
  let out = FixedArray::make(per_row * image.height, b'\x00')
  for y in 0..<image.height {
    converter.expanded(
      image.row(y),
      image.width,
      out.mut_view(start=y * per_row, end=(y + 1) * per_row),
    )
  }
  if depth == 16 {
    for i = 0; i + 1 < out.length(); i = i + 2 {
      let high = out[i]
      out[i] = out[i + 1]
      out[i + 1] = high
    }
  }
  let color : @codecs.ColorType = match (channels, depth) {
    (1, 8) => L8
    (1, _) => L16
    (2, 8) => La8
    (2, _) => La16
    (3, 8) => Rgb8
    (3, _) => Rgb16
    (_, 8) => Rgba8
    _ => Rgba16
  }
  (color, Bytes::from_array(out[:]))
}

///|
/// `message` with its digits as `#`, so that messages that differ only in a
/// number are counted together.
fn without_digits(message : String) -> String {
  let out = StringBuilder()
  for c in message {
    out.write_char(if c >= '0' && c <= '9' { '#' } else { c })
  }
  out.to_string()
}

///|
/// What the comparison with typst makes of `input`: `agree` when both
/// decode the same image or both refuse it, else what each says; and the
/// two errors in full, or where the two images differ.
fn compare(input : Bytes) -> (String, String) {
  let ours = Ok(expand(input)) catch { e => Err(e) }
  let theirs = Ok(@codecs.decode_png(input)) catch {
    @codecs.ImageError(message) => Err(message)
  }
  let details = match (ours, theirs) {
    (Err(e), Err(message)) => "\{@debug.to_string(e)} / \{message}"
    (Err(e), Ok(_)) => @debug.to_string(e)
    (Ok(_), Err(message)) => message
    (Ok((color, pixels)), Ok((info, theirs))) => {
      let mut at = 0
      while at < pixels.length() &&
            at < theirs.length() &&
            pixels[at] == theirs[at] {
        at += 1
      }
      let ours = if at < pixels.length() { pixels[at].to_int() } else { -1 }
      let typst = if at < theirs.length() { theirs[at].to_int() } else { -1 }
      "\{@debug.to_string(color)}, \{@debug.to_string(info.color)}; byte \{at}: \{ours}, \{typst}"
    }
  }
  let outcome = match (ours, theirs) {
    (Err(_), Err(_)) => "agree: both refuse it"
    (Ok((color, pixels)), Ok((info, theirs))) =>
      if color == info.color && pixels == theirs {
        "agree: the same image"
      } else {
        "both decode, other images"
      }
    (Err(e), Ok(_)) => "ours \{kind_name(e)}, typst decodes"
    (Ok(_), Err(message)) => "ours decodes, typst: \{without_digits(message)}"
  }
  (outcome, details)
}

///|
/// Whether to print every input on which the two disagree (`--list`).
let listing : Ref[Bool] = Ref(false)

///|
/// What a damaged case is, without its positions: `fix 3:IDAT 17.2` is
/// `fix IDAT`, `trunc 40` is `trunc`.
fn category(desc : String) -> String {
  let words = desc.split(" ").map(w => w.to_owned()).collect()
  let head = words[0]
  if words.length() > 1 {
    let second = words[1]
    match second.find(":") {
      Some(i) if head != "type" =>
        return "\{head} \{second.view(start_offset=i + 1)}"
      _ => ()
    }
  }
  head
}

///|
priv struct Tally {
  /// The streaming decoder's outcomes, without and with chunks to report.
  plain : Map[String, Int32]
  reporting : Map[String, Int32]
  /// The comparison's outcomes, by what disagrees, then by category, with an
  /// example of each.
  compared : Map[String, Map[String, (Int32, String)]]
  mut cases : Int32
  mut broken : Int32
}

///|
fn bump(map : Map[String, Int32], key : String) -> Unit {
  map.set(key, map.get_or_default(key, 0) + 1)
}

///|
fn Tally::add(
  self : Tally,
  input : Bytes,
  category : String,
  label : String,
) -> Unit {
  self.cases += 1
  let plain = stream(input, [])
  let reporting = stream(input, reported)
  bump(self.plain, plain)
  bump(self.reporting, reporting)
  if !is_kind(plain) || !is_kind(reporting) {
    self.broken += 1
    println("CONTRACT \{label}: \{plain}; reporting: \{reporting}")
  }
  let (compared, details) = compare(input)
  if listing.val && !compared.has_prefix("agree") {
    println("DIFF \{label}: \{compared}: \{details} [streaming: \{plain}]")
  }
  let groups = match self.compared.get(compared) {
    Some(groups) => groups
    None => {
      let groups = Map([])
      self.compared.set(compared, groups)
      groups
    }
  }
  let (n, example) = groups.get_or_default(category, (0, label))
  groups.set(category, (n + 1, example))
}

///|
/// Whether `outcome` is a decoded image or an error the contract allows.
fn is_kind(outcome : String) -> Bool {
  match outcome {
    "ok"
    | "Truncated"
    | "Corrupt"
    | "ChecksumMismatch"
    | "TrailingData"
    | "Unsupported" => true
    _ =>
      outcome.has_prefix("LimitExceeded(") ||
      outcome.has_prefix("DictionaryRequired(")
  }
}

///|
fn Tally::print(self : Tally, title : String) -> Unit {
  println(
    "== \{title}: \{self.cases} inputs, \{self.broken} broke the contract",
  )
  for item in [("streaming", self.plain), ("reporting", self.reporting)] {
    let (name, map) = item
    println("-- \{name}")
    let rows = map.to_array()
    rows.sort_by((a, b) => b.1.compare(a.1))
    for row in rows {
      println("\{row.1}\t\{row.0}")
    }
  }
  println("-- against typst's decode_png")
  let rows = self.compared.to_array()
  rows.sort_by((a, b) => a.0.compare(b.0))
  for row in rows {
    let (outcome, groups) = row
    let total = groups.values().fold(init=0, (n, g) => n + g.0)
    println("\{total}\t\{outcome}")
    if outcome.has_prefix("agree") {
      continue
    }
    for category, g in groups {
      println("\t\{g.0}\t\{category}\te.g. \{g.1}")
    }
  }
}

///|
fn Tally::new() -> Tally {
  {
    plain: Map([]),
    reporting: Map([]),
    compared: Map([]),
    cases: 0,
    broken: 0,
  }
}

///|
/// The seeds of `path`: a `=== name` line before each one's base64 lines.
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
/// usage: png_corpus [--list] [--seeds png_corpus.txt] [DIR...]
/// Decodes the damaged copies of the seeds (see `damage.mbt`), and every
/// file of each directory, with gaato/png's streaming decoder (once as it
/// is, once reporting the text and metadata chunks) and with its one-shot
/// `decode` against typst's `decode_png`, and prints a tally for each.
/// A line `CONTRACT` names an input on which the decoder broke its
/// contract or its memory bound; with `--list`, a line `DIFF` names each
/// input on which gaato/png and typst disagree.
fn main {
  let args = @env.args()
  let mut i = 1
  let dirs = []
  let mut seeds_path = None
  while i < args.length() {
    if args[i] == "--list" {
      listing.val = true
      i += 1
    } else if args[i] == "--seeds" && i + 1 < args.length() {
      seeds_path = Some(args[i + 1])
      i += 2
    } else {
      dirs.push(args[i])
      i += 1
    }
  }
  if seeds_path is Some(path) {
    let tally = Tally::new()
    let seeds = seeds_of(path) catch { e => abort("\{path}: \{e}") }
    for index, seed in seeds {
      let (name, data) = seed
      for case in @damage.png_damage(data, index) {
        tally.add(case.data, category(case.desc), "\{name} \{case.desc}")
      }
    }
    tally.print("typst's damaged seeds")
  }
  for dir in dirs {
    let tally = Tally::new()
    let names = (@fs.read_dir(dir) catch {
      e => abort("\{dir}: \{@debug.to_string(e)}")
    }).to_owned()
    names.sort()
    for name in names {
      let path = "\{dir}/\{name}"
      guard (@fs.is_file(path) catch { _ => false }) else { continue }
      let data = @fs.read_file_to_bytes(path) catch {
        e => abort("\{path}: \{@debug.to_string(e)}")
      }
      tally.add(data, "file", name)
    }
    tally.print(dir)
  }
}
